# frozen_string_literal: true

require_relative "../test_helper"

class TestCLI < Minitest::Test
  def test_context_and_run_commands
    with_repo do |repo|
      repo.write("lib/box.rb", <<~RUBY)
        class Box
          LIMIT = 10
          def n
            LIMIT
          end
        end
      RUBY
      repo.commit("Initial box", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/box.rb", <<~RUBY)
        class Box
          LIMIT = 5
          def n
            LIMIT
          end
        end
      RUBY
      repo.commit("Lower LIMIT from 10 to 5.", date: "2026-02-12T00:00:00Z")

      stdout, stderr, status = cli("context", "--repo", repo.dir, "base", "HEAD")
      assert_equal 0, status, stderr
      assert_equal "", stderr
      assert_includes stdout, "jitcatch context"
      assert_includes stdout, "Box::LIMIT"
      json, json_err, json_status = cli("context", "--json", "--repo", repo.dir, "base", "HEAD")
      assert_equal 0, json_status, json_err
      parsed = JSON.parse(json)
      assert_equal "context", parsed["command"]
      assert_equal "Box::LIMIT", parsed["constants"].fetch(0)["name"]

      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "n_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "box"

          class NTest < Minitest::Test
            def test_n_was_ten
              assert_equal 10, Box.new.n
            end
          end
        RUBY
      })
      run_out, run_err, run_status = cli("run", "--repo", repo.dir, "--reruns", "0", "--workers", "2", "base", "HEAD", tests)
      assert_equal 0, run_status, run_err
      assert_includes run_out, "counts "
      assert_includes run_out, "jitcatch run"

      json_run, json_run_err, json_run_status = cli(
        "run", "--json", "--repo", repo.dir, "--reruns", "0", "--env", "B_VAR", "--env", "A_VAR", "--env", "B_VAR", "base", "HEAD", tests
      )
      assert_equal 0, json_run_status, json_run_err
      assert_equal %w[A_VAR B_VAR], JSON.parse(json_run)["env"]
      report = File.join(repo.dir, "run.json")
      File.write(report, json_run)
      assessed, assessed_err, assessed_status = cli("assess", "--json", report)
      assert_equal 0, assessed_status, assessed_err
      assert_equal JSON.parse(json_run)["counts"], JSON.parse(assessed)["counts"]

      usage, _err, usage_status = cli("nope")
      assert_equal 1, usage_status
      assert_equal "", usage
    end
  end

  def test_help
    stdout, stderr, status = cli
    assert_equal 0, status
    assert_equal "", stderr
    assert_includes stdout, "never calls an LLM"
    assert_equal [stdout, "", 0], cli("--help")
    %w[context run assess].each do |command|
      assert_equal [stdout, "", 0], cli(command, "--help"), command
    end
  end

  def test_version
    assert_equal ["jitcatch #{JitCatch::VERSION}\n", "", 0], cli("--version")
    assert_equal ["jitcatch #{JitCatch::VERSION}\n", "", 0], cli("-v")
    assert_includes cli.first, "jitcatch --version"
  end

  def test_usage_errors_exit_1_and_git_errors_exit_2
    with_repo do |repo|
      repo.write("a.rb", "A = 1\n")
      repo.commit("a", date: "2026-02-11T00:00:00Z")
      {
        %w[context base] => "usage: jitcatch context BASE HEAD",
        %w[run base HEAD] => "usage: jitcatch run BASE HEAD TESTS_DIR",
        %w[assess] => "usage: jitcatch assess RUN.json",
        %w[context --bogus x base HEAD] => "unknown option: --bogus",
        %w[context --repo] => "--repo requires a value",
        %w[run --coverage c.json base HEAD t] => "unknown option: --coverage",
        %w[run --reruns x base HEAD t] => "--reruns requires an integer",
        %w[run --timeout 0 base HEAD t] => "--timeout must be >= 1",
        %w[run --workers 0 base HEAD t] => "--workers must be >= 1",
        # 1 passes both bounds, so the run gets as far as the missing directory.
        %w[run --timeout 1 --workers 1 base HEAD t] => "tests directory not found: t",
        %w[run --serial --workers 2 base HEAD t] => "--serial runs one process at a time, so it takes no --workers above 1",
        %w[run --serial base HEAD t] => "tests directory not found: t",
        %w[context --serial base HEAD] => "unknown option: --serial",
        %w[run --env 1X base HEAD t] => "--env needs a variable name, not 1X",
        %w[run --env LANG base HEAD t] => "--env cannot pass LANG: jitcatch sets it",
        %w[run --env BUNDLE_GEMFILE base HEAD t] => "--env cannot pass BUNDLE_GEMFILE: jitcatch sets it",
        %w[run --env TEST_ENV_NUMBER base HEAD t] => "--env cannot pass TEST_ENV_NUMBER: jitcatch sets it",
        %w[assess missing.json] => "run json not found: missing.json"
      }.each do |args, message|
        assert_equal ["", "jitcatch: #{message}\n", 1], cli(*args), args.join(" ")
      end
      _out, err, status = cli("context", "--repo", repo.dir, "nope", "HEAD")
      assert_equal 2, status
      assert_match(/\Ajitcatch: git rev-parse failed: fatal: /, err)
    end
  end

  def test_run_stops_when_neither_side_can_load_its_bundle
    with_repo do |repo|
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "jitcatch_absent_gem", "9.9.9"\n))
      repo.write("lib/flag.rb", "module Flag\n  ON = true\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  ON = false\nend\n")
      repo.commit("Turn the flag off.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => %(require "minitest/autorun"\nrequire "flag"\n\nclass FlagTest < Minitest::Test\n  def test_on = assert(Flag::ON)\nend\n) })
      base, head = %w[base HEAD].map { |ref| repo.git("rev-parse", ref).strip }
      command = %(ruby -e 'require "bundler/setup"; require "minitest"')
      missing = "Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems."

      (text_out, text_err, text_status), (json_out, json_err, json_status) = without_bundler_settings do
        [cli("run", "--repo", repo.dir, "base", "HEAD", tests), cli("run", "--json", "--repo", repo.dir, "base", "HEAD", tests)]
      end

      assert_equal [3, ""], [text_status, text_out]
      assert_equal <<~TEXT, text_err
        jitcatch: setup failed, so no test ran; a test cannot pass or fail on a side that cannot load
        base #{base}
        head #{head}
        setup base failed: #{command}
          #{missing}
        setup head failed: #{command}
          #{missing}
        Run that command in a checkout of that side, fix what it says (often `bundle install` there), and run jitcatch again.
      TEXT
      assert_equal [3, ""], [json_status, json_err]
      side = ->(name, sha) { { "side" => name, "commit" => sha, "command" => command, "stderr" => [missing], "not_passed" => [] } }
      assert_equal(
        { "version" => JitCatch::VERSION, "command" => "run", "error" => "setup_failed", "stage" => "setup", "base" => base, "head" => head,
          "setup_failed" => [side.("base", base), side.("head", head)] },
        JSON.parse(json_out)
      )
    end
  end

  # A run whose every file timed out compared nothing, so it must not read
  # like a clean change. The child gets only the names --env passes, and a
  # name the code reads is a common reason for the wait.
  def test_run_exits_3_when_every_row_timed_out_and_names_what_the_child_did_not_get
    with_repo do |repo|
      repo.write("lib/flag.rb", %(module Flag\n  def self.ok = ENV.fetch("JITCATCH_SLOW_SERVICE", "") != ""\nend\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "slow_test.rb" => %(require "minitest/autorun"\nrequire "flag"\n\nclass SlowTest < Minitest::Test\n  def test_slow\n    sleep 60\n    assert Flag.ok\n  end\nend\n) })

      out, err, status = with_parent_env("JITCATCH_SLOW_SERVICE" => "on", "HTTPS_PROXY" => "http://proxy.invalid:3128") do
        cli("run", "--repo", repo.dir, "--timeout", "1", "base", "HEAD", tests)
      end

      assert_equal [3, ""], [status, err]
      assert_equal "jitcatch: no row ran to a result on both sides (1 of 1 timed out or found no database), so this run cannot tell base from head\n", out.lines.first
      assert_includes out, "    hint: base and head timed out after 1s; raise --timeout if the file needs longer, as a Rails app's first run in a new checkout can (it loads db/schema.rb)\n" \
        "    not passed: HTTPS_PROXY JITCATCH_SLOW_SERVICE (add --env HTTPS_PROXY --env JITCATCH_SLOW_SERVICE if the file needs them)\n"

      json, _err, json_status = with_parent_env("JITCATCH_SLOW_SERVICE" => "on", "HTTPS_PROXY" => "http://proxy.invalid:3128") do
        cli("run", "--json", "--repo", repo.dir, "--timeout", "1", "--env", "JITCATCH_SLOW_SERVICE", "base", "HEAD", tests)
      end
      doc = JSON.parse(json)
      assert_equal [3, 1, ["HTTPS_PROXY"]], [json_status, doc["untested"], doc["env_not_passed"]]
    end
  end

  def test_assess_rejects_a_run_that_stopped_on_setup
    Dir.mktmpdir("jitcatch-assess-") do |dir|
      path = File.join(dir, "run.json")
      File.write(path, JSON.generate({ "command" => "run", "error" => "setup_failed", "setup_failed" => [] }))
      assert_equal ["", "jitcatch: run json is a run that stopped on a setup failure, so it has no tests to assess\n", 1], cli("assess", path)
    end
  end

  def test_assess_rejects_a_file_that_is_not_a_run_object
    Dir.mktmpdir("jitcatch-assess-") do |dir|
      list = File.join(dir, "list.json")
      File.write(list, "[]")
      assert_equal ["", "jitcatch: run json must be an object\n", 1], cli("assess", list)
      broken = File.join(dir, "broken.json")
      File.write(broken, "{")
      out, err, status = cli("assess", broken)
      assert_equal ["", 1], [out, status]
      assert_match(/\Ajitcatch: run json is not JSON: /, err)
    end
  end

  def test_bin_exits_with_the_cli_status
    bin = File.expand_path("../../bin/jitcatch", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, bin, "nope")
    assert_equal 1, status.exitstatus
    assert_equal "", stdout
    assert_match(/\Ajitcatch: unknown command: nope\n/, stderr)
  end

  def test_context_reads_non_ascii_git_output_under_the_c_locale
    with_repo do |repo|
      repo.write("lib/box.rb", "class Box\n  def n\n    10\n  end\nend\n")
      repo.commit("Initial box", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      File.binwrite(File.join(repo.dir, "lib/box.rb"), "class Box\n  def n\n    # caf\xC3\xA9 \xFF\n    5\n  end\nend\n".b)
      repo.commit("Lower n for the café.", date: "2026-02-12T00:00:00Z")

      bin = File.expand_path("../../bin/jitcatch", __dir__)
      stdout, stderr, status = Open3.capture3(
        { "LANG" => "C", "LC_ALL" => "C" }, RbConfig.ruby, bin, "context", "--repo", repo.dir, "base", "HEAD"
      )

      assert_equal [0, ""], [status.exitstatus, stderr]
      text = stdout.force_encoding(Encoding::UTF_8)
      assert_includes text, "  Lower n for the café.\n"
      assert_includes text, "# café ?\n"
    end
  end

  # Only the names under test, so the result does not depend on the
  # proxy or certificate settings of the machine that runs the suite.
  def with_parent_env(names)
    saved = ENV.to_h
    ENV.keys.grep(/proxy|\ASSL_CERT_|\ANODE_EXTRA_CA_CERTS\z/i).each { |key| ENV.delete(key) }
    names.each { |key, value| ENV[key] = value }
    yield
  ensure
    ENV.replace(saved)
  end

  def cli(*args)
    status = nil
    stdout, stderr = capture_io { status = JitCatch::CLI.start(args) }
    [stdout, stderr, status]
  end
end
