# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "uri"

module JitCatch
  # Runs each candidate file on base and head worktrees and classifies it.
  class Runner
    FILE_CAP = 40
    PASSED_ENV = %w[PATH HOME USER LOGNAME TMPDIR TEMP TMP LD_LIBRARY_PATH GEM_HOME GEM_PATH].freeze
    FIXED_ENV = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8", "TERM" => "dumb" }.freeze
    # Names jitcatch sets itself, so --env cannot pass them.
    RESERVED_ENV = (FIXED_ENV.keys + %w[BUNDLE_GEMFILE TEST_ENV_NUMBER]).freeze
    # How a child reaches the network. Tools read both https_proxy and
    # HTTPS_PROXY, so the case does not matter.
    NETWORK_ENV = /\A(?:(?:HTTPS?|NO|ALL)_PROXY|SSL_CERT_(?:FILE|DIR)|NODE_EXTRA_CA_CERTS)\z/i
    ENV_READ = /ENV(?:\.fetch\(\s*|\.key\?\(\s*|\[\s*)["']([A-Za-z_][A-Za-z0-9_]*)["']/
    ENV_READ_GREP = %q{ENV(\.fetch\(|\.key\?\(|\[) *["'][A-Za-z_][A-Za-z0-9_]*["']}
    # What reads a proxy or CA setting: an HTTP client, by the name a file
    # requires or a Gemfile.lock lists, and a command a file starts that
    # fetches, such as `npx --yes` or `bundle install`, in a string, a
    # backtick, or an argument list. A spec of a local SQLite app uses none,
    # so the host's proxy settings are noise there. A command spelled any
    # other way, as in a script file, is not seen.
    NETWORK_REQUIRES = %w[net/http net/https open-uri faraday httparty excon http httpx httpclient rest-client typhoeus].freeze
    NETWORK_GEMS = %w[net-http faraday httparty excon http httpx httpclient rest-client typhoeus].freeze
    NETWORK_COMMANDS = %w[npx npm curl wget].freeze
    FETCHING_TOOLS = %w[bundle gem git].freeze
    FETCHING_SUBCOMMANDS = %w[install update clone fetch pull].freeze
    NETWORK_USE_GREP = "require *\\(? *[\"'](#{NETWORK_REQUIRES.join("|")})[\"']|[\"'`](#{NETWORK_COMMANDS.join("|")}) " \
                       "|[\"'`](#{FETCHING_TOOLS.join("|")})([\"'], *[\"']| +)(#{FETCHING_SUBCOMMANDS.join("|")})"
    NETWORK_USE = Regexp.new(NETWORK_USE_GREP)
    # Rescuing in the child keeps Bundler's own message and drops its backtrace.
    BUNDLE_SETUP = 'begin; require "bundler/setup"; rescue Exception => e; $stderr.puts e.message; exit 1; end'
    SETUP_STDERR_LINES = 10
    # A database server that refused the connection, as PostgreSQL and MySQL
    # clients word it. The client then took its host and port from a default,
    # often because the shell's setting for them was not passed.
    DATABASE_REFUSED = /Connection refused|could not connect to server|Can't connect to (?:local )?(?:MySQL )?server/
    # What an app's database.yml or its client library reads: libpq reads
    # PG* itself, and Rails reads DATABASE_URL and its per-database forms.
    DATABASE_ENV = /\A(?:(?:\w+_)?DATABASE_URL|DB_\w+|PG[A-Z]+|MYSQL_\w+)\z/
    SQLITE_RELATIVE = "relative path, as sqlite3:storage/test.sqlite3, so each checkout opens a file under its own root"
    # The test databases of a side, as Active Record reads config/database.yml
    # with that side's TEST_ENV_NUMBER and the variables --env passes, so a
    # DATABASE_URL merges in as it does when rails_helper sets RAILS_ENV.
    TEST_DATABASES = <<~'SCRIPT'
      ENV["RAILS_ENV"] ||= "test"
      require "json"
      require "active_record"
      require "active_record/database_configurations"
      require "active_support/configuration_file"
      configs = ActiveRecord::DatabaseConfigurations.new(ActiveSupport::ConfigurationFile.parse("config/database.yml")).configs_for(env_name: "test")
      print JSON.generate(configs.map { |config| config.configuration_hash.slice(:adapter, :host, :port, :socket, :database).transform_values(&:to_s) })
    SCRIPT
    # `lines` maps an RSpec example's name to the line it starts on.
    Result = Data.define(:tests, :lines, :file_error, :timed_out, :exit_code, :seconds)
    # One worker's two checkouts. A worker runs one file at a time in them.
    Pair = Data.define(:base, :head)
    # The names a test can mention, and the constants head defines.
    # `unsaved` maps a `build(:loan)` that only a callback lists to the
    # record calls that make it run that callback.
    # `routes` are the routes head's config/routes.rb draws.
    Known = Data.define(:names, :constants, :unsaved, :routes)

    def self.run(repo, base_ref, head_ref, tests_dir, reruns: 2, timeout: nil, env: [], workers: 1, serial: false, number_database_url: false, setup: nil, finished_in_time: nil)
      new(repo, base_ref, head_ref, tests_dir, reruns: reruns, timeout: timeout, env: env, workers: workers, serial: serial,
        number_database_url: number_database_url, setup: setup, finished_in_time: finished_in_time).run
    end

    # `finished_in_time` takes the thread that waits on a child and says
    # whether the child ended before the timeout. A test passes its own so
    # that which child times out does not depend on the machine's load.
    # `setup` is a shell command run once in each checkout before its
    # candidates, such as a schema load into that checkout's database.
    def initialize(repo, base_ref, head_ref, tests_dir, reruns:, timeout:, env:, workers: 1, serial: false, number_database_url: false, setup: nil, finished_in_time: nil)
      @git = repo.is_a?(GitRepo) ? repo : GitRepo.new(repo)
      @setup = setup
      @base_ref = base_ref
      @head_ref = head_ref
      @tests_dir = File.expand_path(tests_dir)
      @reruns = reruns
      @timeout = timeout
      @finished_in_time = finished_in_time || ->(waiter) { !waiter.join(@timeout).nil? }
      @env_names = env.uniq.sort
      @workers = workers
      raise UsageError, "--workers must be at least 1" unless workers.is_a?(Integer) && workers >= 1
      # Candidates that share a fixed path or port outside the worktree
      # collide when two processes run at once; serial runs one at a time.
      raise UsageError, "--serial runs one process at a time, so it takes no --workers above 1" if serial && workers > 1

      @serial = serial
      raise UsageError, "tests directory not found: #{tests_dir}" unless File.directory?(@tests_dir)

      @number_database_url = number_database_url
      check_database_url if number_database_url
    end

    def check_database_url
      raise UsageError, "--number-database-url numbers the DATABASE_URL that --env passes, so pass --env DATABASE_URL" unless @env_names.include?("DATABASE_URL")
      return if ENV["DATABASE_URL"] && numbered_database_url(ENV["DATABASE_URL"], "1")
      raise UsageError, "--number-database-url numbers only a database server's database, and DATABASE_URL names an SQLite file; give it a #{SQLITE_RELATIVE}" if sqlite_url?(ENV["DATABASE_URL"])

      raise UsageError, "--number-database-url needs DATABASE_URL to name a database, as postgresql://localhost/app_test does; it #{ENV["DATABASE_URL"] ? "names none" : "is not set"}"
    end

    # An SQLite URL names a file, not a database on a server, so there is
    # no database to number; a relative path already gives each checkout
    # its own file.
    def sqlite_url?(url)
      url.to_s.match?(/\Asqlite3?:/i)
    end

    # `postgresql://host/app_test_wt1?sslmode=disable` with number 2 is
    # `postgresql://host/app_test_wt1_2?sslmode=disable`. Nil when the URL
    # names no database on a server.
    def numbered_database_url(url, number)
      return nil if sqlite_url?(url)

      uri = URI.parse(url)
      name = uri.path.to_s.delete_prefix("/")
      return nil if name.empty? || name.include?("/")

      uri.path = "/#{name}_#{number}"
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def run
      files, omitted = candidate_files
      @frameworks = files.to_h { |relative| [relative, Framework.for(relative, read_candidate(relative))] }
      @pair_count = [@workers, files.size].min.clamp(1, nil)
      changes = Changes.new(@git, @base_ref, @head_ref, setup: @setup, databases: numbered_databases)
      change = changes.build
      parent = Dir.mktmpdir("jitcatch-")
      pairs = (1..@pair_count).map { |n|
        Pair.new(base: File.join(parent, n.to_s, "base"), head: File.join(parent, n.to_s, "head"))
      }
      # The variable parallel_tests sets: a Rails database.yml that appends
      # it to the database name gives each checkout its own database, so base
      # and head never load their schemas into one database at the same time.
      @test_env_numbers = pairs.each_with_index.flat_map { |pair, index| [[pair.base, (2 * index + 1).to_s], [pair.head, (2 * index + 2).to_s]] }.to_h
      begin
        # One at a time: git takes a lock on the repository for each add.
        pairs.each { |pair| check_out(pair, change) }
        rails_app = File.file?(File.join(pairs.first.head, "config", "application.rb"))
        # A Rails app boots and loads db/schema.rb in each new checkout.
        @timeout ||= rails_app ? 60 : 10
        normalizer = build_normalizer([*pairs.flat_map { |pair| [pair.base, pair.head] }, @git.dir])
        first = pairs.first
        frameworks = @frameworks.values.uniq
        base_setup = Thread.new { setup_status("base", change["base"], first.base, normalizer, frameworks) }
        head_setup = setup_status("head", change["head"], first.head, normalizer, frameworks)
        setups = [base_setup.value, head_setup]
        failed = setups.filter_map { |setup| setup["failure"] }
        raise EnvironmentError, setup_failed_doc(change, failed, rails_app: rails_app) unless failed.empty?

        ran = run_setup(pairs, change, normalizer)
        raise EnvironmentError, setup_failed_doc(change, ran, rails_app: rails_app, stage: "setup_command") unless ran.empty?

        bundle = { "base" => setups[0]["bundle"], "head" => setups[1]["bundle"] }
        shared = shared_test_database(first)
        @serial ||= !shared.nil?
        routes_file = File.join(first.head, "config", "routes.rb")
        inflections_file = File.join(first.head, "config", "initializers", "inflections.rb")
        routes = Routes.parse(File.file?(routes_file) ? read_text(routes_file) : nil, Inflections.read(File.file?(inflections_file) ? read_text(inflections_file) : nil))
        helper_warnings = File.file?(routes_file) ? route_helper_warnings(files, routes) : []
        known = Known.new(names: mention_names(change), constants: changes.head_constants, unsaved: unsaved_mentions(change), routes: routes)
        rows = classify_files(files, shared ? [first] : pairs, normalizer, known)
        bundled = gemfile?(first.head)
        spec_root = File.exist?(File.join(first.head, "spec"))
        launcher = @frameworks.value?(Framework::RSpec) && launcher_loads?
        rows.each { |row| row["rerun"] = rerun_command(row, bundled, !spec_root, launcher) }
        unloaded = load_failure_doc(change, rows, bundled, rails_app)
        raise EnvironmentError, unloaded if unloaded
      ensure
        pairs.each do |pair|
          @git.worktree_remove(pair.base)
          @git.worktree_remove(pair.head)
        end
        @git.worktree_prune
        FileUtils.remove_entry(parent) if parent && File.directory?(parent)
      end
      assign_test_ids(rows)
      {
        "version" => VERSION,
        "command" => "run",
        "base" => change["base"],
        "head" => change["head"],
        "warnings" => change["warnings"] + require_warnings(files) + helper_warnings + [*(shared_database_warnings(shared) if shared)],
        "reruns" => @reruns,
        "timeout_s" => @timeout,
        "serial" => @serial,
        "setup" => @setup,
        "numbered_databases" => numbered_databases,
        "env" => @env_names,
        "env_unset" => @env_names.reject { |name| ENV.key?(name) },
        "rails_app" => rails_app,
        "env_not_passed" => rows.any? { |row| %w[base head].any? { |side| row.dig(side, "status") == "timeout" } } ? env_not_passed(change["head"], files) : [],
        "bundle" => bundle,
        "tests_dir" => tests_from_root,
        "test_files_omitted" => omitted,
        "dependencies" => change["dependencies"],
        "methods" => change["methods"].map { |method| slim_method(method) },
        "constants" => change["constants"].map { |const| slim_constant(const) },
        "changed_lines" => change["changed_lines"],
        "tests" => rows
      }
    end

    private

    def check_out(pair, change)
      if @git.empty_tree?(change["base"])
        FileUtils.mkdir_p(pair.base)
      else
        @git.worktree_add(pair.base, change["base"])
      end
      @git.worktree_add(pair.head, change["head"])
      [pair.base, pair.head].each do |worktree|
        install(worktree)
        copy_bundler_settings(worktree)
      end
    end

    # Each worker takes the next file and runs it in its own pair, so the
    # rows do not depend on which worker ran which file.
    def classify_files(files, pairs, normalizer, known)
      queue = Queue.new
      files.each { |relative| queue << relative }
      queue.close
      threads = pairs.map { |pair|
        Thread.new do
          found = []
          while (relative = queue.pop)
            found.concat(classify_file(relative, pair.base, pair.head, normalizer, known))
          end
          found
        end
      }
      threads.flat_map(&:value)
    end

    def classify_file(relative, base_dir, head_dir, normalizer, known)
      source = read_candidate(relative)
      index = SourceIndex.parse(source, file: relative)
      # Each side runs in its own worktree, so the two can run at once.
      if @serial
        base_run = execute(base_dir, relative, normalizer)
        head_run = execute(head_dir, relative, normalizer)
      else
        base_thread = Thread.new { execute(base_dir, relative, normalizer) }
        head_run = execute(head_dir, relative, normalizer)
        base_run = base_thread.value
      end
      rows = rows_for(relative, base_run, head_run, index, known, head_dir)
      return rows unless rows.any? { |row| row["classification"] == "candidate" }
      return rows if head_run.timed_out || base_run.timed_out

      @reruns.times do
        rerun = execute(head_dir, relative, normalizer)
        rows.each do |row|
          next unless row["classification"] == "candidate"
          next if load_row?(row)

          again = rerun.tests[row["name"]] || missing_result
          (row["reruns"] ||= []) << again.slice("status", "error_class", "message_first_line", "message")
          next if failure_key(again) == failure_key(row["head"])

          if outcome_key(again) == outcome_key(row["head"]) && row.dig("base", "status") == "pass"
            row["message_varies"] = true
          else
            row["classification"] = "flaky"
          end
        end
        break if rows.none? { |row| row["classification"] == "candidate" }
      end
      confirm_on_base(rows.select { |row| row["classification"] == "candidate" && row["message_varies"] }, base_dir, relative, normalizer)
      rows
    end

    # A test whose head fails the same way each time, with a value in the
    # message that moves, such as a random id, still caught the change when
    # base passes each time too. A test that fails at random is caught here
    # instead: its base fails once in a while as well.
    def confirm_on_base(rows, base_dir, relative, normalizer)
      return if rows.empty?

      @reruns.times do
        rerun = execute(base_dir, relative, normalizer)
        rows.each do |row|
          again = rerun.tests[row["name"]] || missing_result
          (row["base_reruns"] ||= []) << again.slice("status", "error_class", "message_first_line", "message")
          row["classification"] = "flaky" unless again["status"] == "pass"
        end
      end
    end

    def rows_for(relative, base_run, head_run, index, known, head_dir)
      if file_level?(base_run) || file_level?(head_run)
        name = file_level_name(relative, base_run, head_run)
        base_result = side_result(base_run)
        # Only beside a head that timed out does base's time say anything:
        # how far head was from base when it ran out. Kept nowhere else, so
        # every other row stays the same bytes from run to run.
        base_result = base_result.merge("seconds" => base_run.seconds.round(1)) if head_run.timed_out && base_result["status"] == "pass"
        [build_row(relative, name, nil, base_result, side_result(head_run), mentions_for(index, name, nil, known, relative, head_dir))]
      else
        names = (base_run.tests.keys | head_run.tests.keys).sort
        names.map { |name|
          line = head_run.lines[name] || base_run.lines[name]
          build_row(
            relative,
            name,
            line,
            base_run.tests[name],
            head_run.tests[name],
            mentions_for(index, name, line, known, relative, head_dir)
          )
        }
      end
    end

    def file_level?(execution)
      execution.timed_out || execution.file_error
    end

    # A test of its own can also end in "#load", so match the whole name.
    def load_row?(row)
      row["name"] == "#{File.basename(row["file"])}#load"
    end

    def file_level_name(relative, base_run, head_run)
      timed_out = base_run.timed_out || head_run.timed_out
      "#{File.basename(relative)}##{timed_out ? "timeout" : "load"}"
    end

    def side_result(execution)
      return timeout_result if execution.timed_out
      return execution.file_error if execution.file_error
      return pass_result if !execution.tests.empty? && execution.tests.values.all? { |test| test["status"] == "pass" }
      return pass_result if execution.tests.empty? && execution.exit_code.zero?

      values = execution.tests.values
      failed = values.find { |test| test["status"] != "pass" }
      failed || Failure.result("error", "RuntimeError", "no tests ran", [])
    end

    def build_row(relative, name, line, base_result, head_result, mentions)
      base_result = missing_result if base_result.nil?
      head_result = missing_result if head_result.nil?
      {
        "file" => relative.tr("\\", "/"),
        "name" => name,
        "line" => line,
        "mentions" => mentions,
        "classification" => classify(base_result, head_result),
        "base" => base_result,
        "head" => head_result
      }
    end

    # A base that timed out may pass with more time, so a head that did not
    # pass is a candidate the assessor discards, not a test that failed on
    # base.
    def classify(base_result, head_result)
      base_pass = base_result["status"] == "pass"
      head_status = head_result["status"]
      if (base_pass || base_result["status"] == "timeout") && %w[fail error timeout].include?(head_status)
        "candidate"
      elsif base_pass && %w[pass skip].include?(head_status)
        "no_signal"
      else
        "fail_on_base"
      end
    end

    # The whole message is compared: an assertion's first line names the
    # expected value, and the value that moves between runs is on a later line.
    def failure_key(result)
      lines = result["message"].to_s.lines.map(&:strip).reject(&:empty?).join("\n")
      message = Text.mask_times(Text.mask_addresses(temp_roots.reduce(lines) { |text, root| Text.mask_temp_names(text, root) }))
      [result["status"], result["error_class"].to_s, message].join("\x1f")
    end

    def outcome_key(result)
      [result["status"], result["error_class"].to_s]
    end

    # A symlinked temp directory (macOS /tmp) can appear under either name.
    def temp_roots
      @temp_roots ||= [Dir.tmpdir, File.realpath(Dir.tmpdir)].uniq.sort_by { |root| -root.length }
    end

    def execute(worktree, relative, normalizer)
      framework = @frameworks.fetch(relative)
      stdout_path = File.join(worktree, ".jitcatch-stdout")
      stderr_path = File.join(worktree, ".jitcatch-stderr")
      report_path = File.join(worktree, Framework::REPORT)
      FileUtils.rm_f(report_path)
      cmd = [
        RbConfig.ruby,
        *("-rbundler/setup" if gemfile?(worktree)),
        "-I#{File.join(worktree, "lib")}",
        "-I#{worktree}",
        *framework.arguments(File.join(".jitcatch", relative))
      ]
      status, stdout, stderr, timed_out, seconds = run_process(
        cmd,
        chdir: worktree,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        env: child_env(worktree)
      )
      if timed_out
        return Result.new(tests: {}, lines: {}, file_error: nil, timed_out: true, exit_code: nil, seconds: seconds)
      end

      parsed = framework.parse(File.file?(report_path) ? read_text(report_path) : nil, stdout, stderr, normalizer)
      Result.new(
        tests: parsed["tests"].transform_values { |result| Failure.naming_tests(result, tests_from_root) },
        lines: parsed["lines"],
        file_error: Failure.naming_tests(parsed["file_error"], tests_from_root),
        timed_out: false,
        exit_code: status&.exitstatus,
        seconds: seconds
      )
    end

    def run_process(cmd, chdir:, stdout_path:, stderr_path:, env:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = Process.spawn(env, *cmd, chdir: chdir, out: stdout_path, err: stderr_path, pgroup: true, unsetenv_others: true)
      waiter = Process.detach(pid)
      timed_out = !@finished_in_time.call(waiter)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      kill_group(pid) if timed_out
      status = waiter.value
      [status, read_text(stdout_path), read_text(stderr_path), timed_out, seconds]
    end

    def kill_group(pid)
      Process.kill("-TERM", pid)
    rescue Errno::ESRCH
      nil
    else
      sleep 0.1
      begin
        Process.kill("-KILL", pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def read_text(path)
      return "" unless File.file?(path)

      text = File.read(path, mode: "rb")
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("?")
    end

    def child_env(worktree)
      env = (PASSED_ENV + @env_names).to_h { |key| [key, ENV[key]] }.compact
      env["BUNDLE_GEMFILE"] = File.join(worktree, "Gemfile") if gemfile?(worktree)
      env["TEST_ENV_NUMBER"] = @test_env_numbers.fetch(worktree)
      env["DATABASE_URL"] = numbered_database_url(env["DATABASE_URL"], env["TEST_ENV_NUMBER"]) if @number_database_url
      env.merge(FIXED_ENV)
    end

    def gemfile?(worktree)
      File.file?(File.join(worktree, "Gemfile"))
    end

    # A database server that base and head reach under one name is one
    # database, into which each side loads its own schema while the other
    # runs; an SQLite file at a relative path is a file of each worktree.
    # Nil when they share none, or when a side's config/database.yml does
    # not read without booting the app.
    def shared_test_database(pair)
      base = Thread.new { test_databases(pair.base) }
      head = test_databases(pair.head)
      (base.value.to_a & head.to_a).first&.last
    end

    def test_databases(worktree)
      return nil unless File.file?(File.join(worktree, "config", "database.yml"))

      script = [*(BUNDLE_SETUP if gemfile?(worktree)), TEST_DATABASES].join("\n")
      out, status = Open3.capture2(child_env(worktree), RbConfig.ruby, "-e", script, chdir: worktree, unsetenv_others: true, err: File::NULL)
      return nil unless status.success?

      JSON.parse(out).filter_map do |config|
        name = config["database"]
        next [[config["adapter"], config["host"], config["port"], config["socket"], name], name] unless config["adapter"].include?("sqlite")

        full = File.expand_path(name, worktree)
        [[full], full]
      end
    rescue JSON::ParserError
      nil
    end

    # The names to create, without the rest of the URL, which can hold a
    # password.
    def numbered_databases
      return [] unless @number_database_url

      (1..2 * @pair_count).map { |number| URI.parse(numbered_database_url(ENV["DATABASE_URL"], number.to_s)).path.delete_prefix("/") }
    end

    # One line says what happened, and one says how to run both sides at
    # once. Rails reads a DATABASE_URL that names a database over the
    # `database:` of database.yml, so then only the URL can split it, and
    # one that names none takes `database:` from the file. A past commit's
    # database.yml cannot change, so for it the run one process at a time is
    # the one to keep.
    def shared_database_warnings(name)
      numbers = @test_env_numbers.values.sort_by(&:to_i)
      happened = "base and head use one test database, #{name}, so jitcatch ran one process at a time; that changes how long the run takes, not its results."
      url = ENV["DATABASE_URL"] if @env_names.include?("DATABASE_URL")
      remedy = if url && numbered_database_url(url, "1")
        "To run them at once, add --number-database-url: each checkout then adds its TEST_ENV_NUMBER to the database name in DATABASE_URL " \
          "(#{numbers.map { |number| "#{name}_#{number}" }.join(", ")}), and you create those databases once. " \
          "Numbering database: in config/database.yml does not split it, because a DATABASE_URL that names a database wins over database:."
      elsif sqlite_url?(url)
        "To run them at once, give DATABASE_URL a #{SQLITE_RELATIVE}. --number-database-url numbers only a database server's database."
      else
        "To run them at once, end the test database name in config/database.yml with <%= ENV[\"TEST_ENV_NUMBER\"] %> " \
          "and create the numbered databases: for n in #{numbers.join(" ")}; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done. " \
          "This helps only when BASE and HEAD both have that line."
      end
      [happened, remedy]
    end

    # One check per side, so a side that cannot load its bundle or a
    # framework is said once, as the setup failure it is, instead of as a
    # load error on every candidate file.
    def setup_status(side, commit, worktree, normalizer, frameworks)
      bundled = gemfile?(worktree)
      bundle = bundled ? "ok" : "none"
      # Every framework is tried, so one run names all that are missing.
      checks = frameworks.map { |framework|
        "begin; require #{framework::LIBRARY.inspect}; rescue LoadError; $stderr.puts #{framework.missing(bundled).inspect}; missing = true; end"
      }
      status, _stdout, stderr, timed_out = run_process(
        [RbConfig.ruby, "-e", [*(BUNDLE_SETUP if bundled), "missing = false", *checks, "exit 1 if missing"].join("; ")],
        chdir: worktree,
        stdout_path: File.join(worktree, ".jitcatch-stdout"),
        stderr_path: File.join(worktree, ".jitcatch-stderr"),
        env: child_env(worktree)
      )
      return { "bundle" => bundle, "failure" => nil } if !timed_out && status&.success?

      requires = [*("bundler/setup" if bundled), *frameworks.map { |framework| framework::LIBRARY }]
      tail = Text.message_lines(normalizer.call(stderr)).last(SETUP_STDERR_LINES)
      failure = {
        "side" => side,
        "commit" => commit,
        "command" => "ruby -e #{Framework::Minitest.quote(requires.map { |library| %(require "#{library}") }.join("; "))}",
        "stderr" => timed_out ? ["timed out after #{@timeout}s"] : tail,
        "not_passed" => bundled ? unpassed_bundler_settings : []
      }
      { "bundle" => bundle, "failure" => failure }
    end

    # Every checkout, so a worker's pair holds the same schemas as the
    # first. One at a time: two loads into one shared database would race.
    # RAILS_ENV is test unless --env passes one, so a schema load never
    # reaches the development database.
    def run_setup(pairs, change, normalizer)
      return [] unless @setup

      pairs.flat_map { |pair| [["base", pair.base], ["head", pair.head]] }.filter_map do |side, worktree|
        env = { "RAILS_ENV" => "test" }.merge(child_env(worktree))
        status, _stdout, stderr, timed_out = run_process(
          ["/bin/sh", "-c", @setup],
          chdir: worktree,
          stdout_path: File.join(worktree, ".jitcatch-stdout"),
          stderr_path: File.join(worktree, ".jitcatch-stderr"),
          env: env
        )
        next if !timed_out && status&.success?

        lines = Text.message_lines(normalizer.call(stderr))
        {
          "side" => side,
          "commit" => change[side],
          "command" => @setup,
          "stderr" => timed_out ? ["timed out after #{@timeout}s"] : lines.last(SETUP_STDERR_LINES),
          "not_passed" => [],
          "database_not_passed" => timed_out ? [] : database_not_passed(lines)
        }
      end.uniq { |failure| failure["side"] }
    end

    # A side that loads its bundle can still fail to boot what every
    # candidate requires, such as a Rails app whose database does not exist.
    # When no file loaded on either side, no row can tell base from head.
    def load_failure_doc(change, rows, bundled, rails_app)
      return nil if rows.empty?
      return nil unless rows.all? { |row| load_row?(row) && row["base"]["status"] == "error" && row["head"]["status"] == "error" }

      first = rows.min_by { |row| row["file"] }
      failed = %w[base head].map { |side|
        result = first[side]
        lines = Text.message_lines(result["message"].to_s)
        # Ruby's own report of an uncaught error already ends in its class.
        lines[0] = "#{result["error_class"]}: #{lines[0]}" unless lines.empty? || lines[0].match?(/\([A-Z][\w:]*\)\z/)
        {
          "side" => side,
          "commit" => change[side],
          "command" => first["rerun"],
          "stderr" => lines.first(SETUP_STDERR_LINES),
          "not_passed" => bundled ? unpassed_bundler_settings : [],
          "database_not_passed" => database_not_passed(lines)
        }
      }
      setup_failed_doc(change, failed, stage: "load", rails_app: rails_app)
    end

    # rails_app: the head has config/application.rb, so a credential that
    # git ignores, such as config/master.key, is a likely cause.
    def setup_failed_doc(change, failed, rails_app:, stage: "setup")
      {
        "version" => VERSION,
        "command" => "run",
        "error" => "setup_failed",
        "stage" => stage,
        "rails_app" => rails_app,
        # A bundle installed for another Ruby reads as gems not installed.
        "ruby" => { "version" => RUBY_VERSION, "path" => RbConfig.ruby },
        "base" => change["base"],
        "head" => change["head"],
        "setup_failed" => failed
      }
    end

    # Bundler reads settings such as BUNDLE_WITHOUT from the environment,
    # and the child gets only the names --env passes. `bundle exec` sets the
    # Gemfile and lockfile names for jitcatch's own bundle, not the checkout's.
    # Names the parent has and the child does not get that a child often
    # waits on: names the head's Ruby source or a candidate reads from ENV,
    # and network settings when either loads an HTTP client.
    def env_not_passed(head, files)
      candidates = files.map { |relative| read_candidate(relative) }
      read = [@git.ruby_matches(head, ENV_READ_GREP), *candidates].flat_map { |text| text.scan(ENV_READ).flatten }
      network = network_library?(head, candidates)
      passed = PASSED_ENV + RESERVED_ENV + @env_names
      ENV.keys.select { |name| (network && name.match?(NETWORK_ENV)) || read.include?(name) }.reject { |name| passed.include?(name) }.sort
    end

    def network_library?(head, candidates)
      locked = @git.show(head, "Gemfile.lock").to_s.scan(/^    (\S+) \(/).flatten
      (locked & NETWORK_GEMS).any? || [@git.ruby_matches(head, NETWORK_USE_GREP), *candidates].any? { |text| text.match?(NETWORK_USE) }
    end

    def database_not_passed(lines)
      return [] unless lines.any? { |line| line.match?(DATABASE_REFUSED) }

      ENV.keys.grep(DATABASE_ENV).sort - @env_names
    end

    def unpassed_bundler_settings
      ENV.keys.grep(/\ABUNDLE_/).sort - %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE] - @env_names
    end

    # `bundle config set --local` writes .bundle/config, which git does not
    # track, so a worktree would load its bundle without the checkout's
    # settings, such as BUNDLE_WITHOUT. A relative BUNDLE_PATH names a
    # directory of the checkout, so it is written out from there.
    def copy_bundler_settings(worktree)
      source = File.join(@git.dir, ".bundle", "config")
      target = File.join(worktree, ".bundle", "config")
      return unless gemfile?(worktree) && File.file?(source) && !File.exist?(target)

      text = File.read(source).gsub(/^BUNDLE_PATH: "?([^"\n]*)"?$/) { %(BUNDLE_PATH: "#{File.expand_path(Regexp.last_match(1), @git.dir)}") }
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, text)
    end

    def install(worktree)
      dest = File.join(worktree, ".jitcatch")
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      Dir.children(@tests_dir).sort.each do |child|
        FileUtils.cp_r(File.join(@tests_dir, child), dest)
      end
    end

    def read_candidate(relative)
      File.read(File.join(@tests_dir, relative), mode: "r:bom|utf-8")
    end

    def candidate_files
      all = Dir.glob("**/*.rb", base: @tests_dir).sort
      named = all.select { |path| Framework.named?(path) }
      list = named.empty? ? all : named
      omitted = 0
      if list.size > FILE_CAP
        omitted = list.size - FILE_CAP
        list = list.first(FILE_CAP)
      end
      [list, omitted]
    end

    # The names a test can mention. A test runs `Owner#initialize` by writing
    # `Owner.new`, so a constructor is mentioned as `Owner.new`, with the
    # owner's last name segment, the shortest way a test can write it, and
    # so is a record builder or a save that runs a changed callback.
    def mention_names(change)
      names = change["methods"].flat_map { |method|
        [method["name"], *method["reached_by"], *method["dynamic_callers"].map { |caller| caller["from"] }].map { |name| Assessor.mention_of(name) } +
          (Array(method["builders"]) + Array(method["run_by"])).flat_map { |name| [name, name.sub(/\A(?:\w+::)+/, "")] }
      }
      names += change["entrypoints"].flat_map { |entry| entry["methods"].map { |method| Assessor.mention_of(method["name"]) } }
      names += change["constants"].map { |const| const["bare_name"] }
      names.compact.uniq.sort.reject(&:empty?)
    end

    # Mentions are taken from the test method and the same-file helpers it
    # calls, so a neighbor test in the same file does not change its tags.
    def mentions_for(index, test_name, line, known, relative, head_dir)
      referenced = (line && index.example_references(line)) || index.referenced_names(test_name)
      referenced -= foreign_calls(index, test_name, line, known.constants)
      referenced += script_names(index.paths_named(test_name, line), relative, head_dir)
      names = known.names
      # A request names the path it sends, which an endpoint's names only
      # through a pattern, so each one becomes the endpoints it reaches, and
      # the controller action the routes draw for it.
      endpoints = names.select { |name| SourceIndex.endpoint?(name) }
      referenced = referenced.flat_map { |name|
        next [name] unless SourceIndex.request?(name)

        actions = known.routes.actions(name)
        [name, *endpoints.select { |endpoint| SourceIndex.endpoint_call?(name, endpoint) }, *actions, *actions.map { |action| SourceIndex.split_qualified(action).last }]
      }.uniq
      referenced.select { |name|
        next false if known.unsaved.key?(name) && !SourceIndex.saves_or_validates?(referenced, known.unsaved[name])

        names.include?(name) || names.include?(SourceIndex.split_qualified(name).last) || names.include?(Assessor.mention_of(name))
      }
    end

    # A `build(:loan)` that builds a changed class runs its constructor
    # whatever the test does next, so only one that no method lists as a
    # builder waits for a save or a validation.
    def unsaved_mentions(change)
      builders = change["methods"].flat_map { |method| Array(method["builders"]) }
      change["methods"].each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |method, found|
        run_by = Array(method["run_by"])
        run_by.select { |name| SourceIndex.unsaved_mention?(name) && !builders.include?(name) }
          .each { |name| found[name] |= SourceIndex.record_calls(run_by) }
      }.to_h
    end

    # `File.write` reaches no method of the repository, so neither it nor
    # the bare `write` it refers to is a mention of `Emitter.write`. A
    # constant counts as the repository's when one it defines ends in it.
    def foreign_calls(index, test_name, line, constants)
      index.names_sent_only_to_constants(test_name, line).flat_map { |bare, receivers|
        next [] if receivers.any? { |const| constants.any? { |name| name == const || name.end_with?("::#{const}") } }

        [bare, *receivers.map { |const| "#{const}.#{bare}" }]
      }
    end

    # A test that starts a script in another process (`IO.popen(["ruby",
    # "exe/tool"])`) reaches the code that script calls, which no call in
    # the test names. A path the test writes, read from the worktree root,
    # from the candidate's directory, or from the candidate file as
    # `File.expand_path` reads it, names such a script when it is a file of
    # head outside `.jitcatch/`; the names it refers to count as mentions.
    def script_names(paths, relative, head_dir)
      candidate = File.join(head_dir, ".jitcatch", relative)
      root = File.join(head_dir, "")
      own = File.join(head_dir, ".jitcatch", "")
      paths.flat_map { |path|
        [head_dir, File.dirname(candidate), candidate].map { |dir| File.expand_path(path, dir) }
          .select { |full| full.start_with?(root) && !full.start_with?(own) && File.file?(full) }
      }.uniq.flat_map { |full|
        relative_path = full.delete_prefix(root)
        script = SourceIndex.parse(read_text(full), file: relative_path)
        # Starting an executable runs its top-level code, which the change
        # document lists as one method when the diff edits it.
        main = SourceIndex.script_path?(relative_path) ? [SourceIndex.script_name(relative_path)] : []
        script.parse_error ? main : main + script.referenced_names("")
      }
    end

# The run loads each candidate from `.jitcatch/` at a checkout's root,
# and the rerun line from TESTS_DIR, so a require_relative that leaves
# TESTS_DIR resolves to two files unless TESTS_DIR sits at the root.
    # A helper that config/routes.rb draws through `draw`, a loop, or a
    # concern is not read, so a request to it ties its row to no action.
    def route_helper_warnings(files, routes)
      helpers = files.flat_map { |relative|
        SourceIndex.parse(read_candidate(relative), file: relative).referenced_names(nil)
          .select { |name| SourceIndex.route_helper_request?(name) }.map { |name| name.split(" ", 2).last }
      }.uniq.sort.reject { |helper| routes.helper?(helper) }
      return [] if helpers.empty?

      requests = helpers.size == 1 ? "1 candidate request names a path helper" : "#{helpers.size} candidate requests name path helpers"
      ["#{requests} config/routes.rb does not draw (#{helpers.join(", ")}), so #{helpers.one? ? "it is" : "they are"} tied to no controller action."]
    end

    def require_warnings(files)
      tests = File.realpath(@tests_dir)
      # From a directory directly under the root, a path that stays in
      # TESTS_DIR and one that leaves it each name one file either way.
      one_level = !tests_from_root.include?("/") && !%w[. ..].include?(tests_from_root)
      files.flat_map do |relative|
        SourceIndex.relative_requires(read_candidate(relative)).filter_map do |required|
          if required.path.nil?
            next if one_level

            next "#{relative}:#{required.line} require_relative names a path the source does not settle, so jitcatch cannot tell whether the run and the rerun line load the same file. Load the repository's code with `require` and the rerun line's -I, or put TESTS_DIR directly under the repository root."
          end

          path = required.path.end_with?(".rb") ? required.path : "#{required.path}.rb"
          in_run = Pathname(File.expand_path(path, File.dirname(File.join("/.jitcatch", relative)))).relative_path_from(Pathname("/")).to_s
          in_rerun = from_root(File.expand_path(path, File.dirname(File.join(tests, relative))))
          next if in_run.start_with?(".jitcatch/") || in_run == in_rerun

          "#{relative}:#{required.line} require_relative #{required.path.inspect} loads #{in_run} in the run but #{in_rerun} from the rerun line, so that line may not reproduce the row. Load the repository's code with `require` and the rerun line's -I, or put TESTS_DIR directly under the repository root."
        end
      end
    end

    # A file-level row (`file#load`, `file#timeout`) reruns the whole file.
    def rerun_command(row, bundled, pin_root, launcher)
      file_level = row["line"].nil? && row["name"].start_with?("#{File.basename(row["file"])}#")
      name = file_level ? nil : row["name"]
      command = @frameworks.fetch(row["file"]).rerun(File.join(tests_from_root, row["file"]), name, row["line"], pin_root: pin_root, launcher: launcher)
      bundled ? "bundle exec #{command}" : command
    end

    # The rerun line runs in the reader's checkout, whose Gemfile can list
    # jitcatch while the commits under test do not, so the launcher is
    # tried there, with that Gemfile, and not in a worktree.
    def launcher_loads?
      bundled = gemfile?(@git.dir)
      env = (PASSED_ENV + @env_names).to_h { |key| [key, ENV[key]] }.compact.merge(FIXED_ENV)
      script = [*(BUNDLE_SETUP if bundled), "require #{Framework::RSpec::LAUNCHER.inspect}"].join("; ")
      system(env, RbConfig.ruby, "-e", script, chdir: @git.dir, unsetenv_others: true, out: File::NULL, err: File::NULL) == true
    end

    # The rerun line runs from the repository root, so the tests directory
    # is named by its path from there, outside the repository too: a quoted
    # line then names no directory of one machine.
    def tests_from_root
      @tests_from_root ||= from_root(File.realpath(@tests_dir))
    end

    # A path outside the repository is named from the root while that is
    # shorter than its absolute path, as `../catch` beside the checkout is.
    # A climb out of a checkout deep in a home directory to a directory
    # under /tmp is longer than the absolute path, and says less.
    def from_root(full)
      relative = Pathname(full).relative_path_from(Pathname(File.realpath(@git.dir))).to_s
      relative.start_with?("../") && full.length < relative.length ? full : relative
    end

    def assign_test_ids(rows)
      rows.sort_by! { |row| [row["file"], row["name"]] }
      width = [2, rows.size.to_s.length].max
      rows.each_with_index { |row, index| row["id"] = format("t%0#{width}d", index + 1) }
    end

    def slim_method(method)
      method.reject { |key, _| %w[old_source new_source callsites existing_tests entry_point_tests].include?(key) }
    end

    def slim_constant(const)
      const.reject { |key, _| %w[old_source new_source].include?(key) }
    end

    def build_normalizer(roots)
      prefix = RbConfig::CONFIG["prefix"].to_s.sub(%r{/+\z}, "")
      ordered = roots.compact.map { |root| File.expand_path(root).sub(%r{/+\z}, "") }.uniq.sort_by { |item| -item.length }
      # A root can end the path, as `Dir.pwd` does, but `head` must not
      # match the start of `head2`.
      patterns = ordered.map { |root| /#{Regexp.escape(root)}(?![\w.-])/ }
      root = Failure::WORKTREE.chomp("/")
      lambda do |text|
        out = text.to_s.gsub("\r\n", "\n")
        patterns.each { |pattern| out = out.gsub(pattern, root) }
        out = out.gsub("#{prefix}/", "{ruby}/") unless prefix.empty?
        out
      end
    end

    def pass_result
      Failure.passed("pass")
    end

    def missing_result
      Failure.result("error", "Missing", "test did not run", [])
    end

    def timeout_result
      Failure.result("timeout", "Timeout", "timeout", [])
    end
  end
end
