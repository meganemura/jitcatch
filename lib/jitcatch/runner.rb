# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"

module JitCatch
  # Runs each candidate file on base and head worktrees and classifies it.
  class Runner
    FILE_CAP = 40
    Result = Data.define(:tests, :summary, :file_error, :timed_out, :exit_code)

    def self.run(repo, base_ref, head_ref, tests_dir, reruns: 2, timeout: 10, coverage: nil)
      new(repo, base_ref, head_ref, tests_dir, reruns: reruns, timeout: timeout, coverage: coverage).run
    end

    def initialize(repo, base_ref, head_ref, tests_dir, reruns:, timeout:, coverage:)
      @git = repo.is_a?(GitRepo) ? repo : GitRepo.new(repo)
      @base_ref = base_ref
      @head_ref = head_ref
      @tests_dir = File.expand_path(tests_dir)
      @reruns = reruns
      @timeout = timeout
      @coverage = coverage
      raise UsageError, "tests directory not found: #{tests_dir}" unless File.directory?(@tests_dir)
    end

    def run
      change = Changes.between(@git, @base_ref, @head_ref, coverage: @coverage)
      files, omitted = candidate_files
      rows = []
      parent = Dir.mktmpdir("jitcatch-")
      base_dir = File.join(parent, "base")
      head_dir = File.join(parent, "head")
      begin
        @git.worktree_add(base_dir, change["base"])
        @git.worktree_add(head_dir, change["head"])
        install(base_dir)
        install(head_dir)
        normalizer = build_normalizer([base_dir, head_dir, @git.dir])
        files.each do |relative|
          rows.concat(classify_file(relative, base_dir, head_dir, normalizer, change))
        end
      ensure
        @git.worktree_remove(base_dir)
        @git.worktree_remove(head_dir)
        @git.worktree_prune
        FileUtils.remove_entry(parent) if parent && File.directory?(parent)
      end
      assign_test_ids(rows)
      {
        "version" => VERSION,
        "command" => "run",
        "base" => change["base"],
        "head" => change["head"],
        "reruns" => @reruns,
        "timeout_s" => @timeout,
        "test_files_omitted" => omitted,
        "methods" => change["methods"].map { |method| slim_method(method) },
        "constants" => change["constants"].map { |const| slim_constant(const) },
        "tests" => rows
      }
    end

    private

    def classify_file(relative, base_dir, head_dir, normalizer, change)
      source = File.read(File.join(@tests_dir, relative), mode: "r:bom|utf-8")
      known = known_names(change)
      index = SourceIndex.parse(source, file: relative)
      base_run = execute(base_dir, relative, normalizer)
      head_run = execute(head_dir, relative, normalizer)
      rows = rows_for(relative, base_run, head_run, index, known, source)
      return rows unless rows.any? { |row| row["classification"] == "candidate" }
      return rows if head_run.timed_out

      @reruns.times do
        rerun = execute(head_dir, relative, normalizer)
        rows.each do |row|
          next unless row["classification"] == "candidate"
          next if row["name"].end_with?("#load", "#timeout")

          again = rerun.tests[row["name"]]
          again = file_level_result(rerun) if again.nil? && (rerun.timed_out || rerun.file_error)
          row["classification"] = "flaky" if again.nil? || failure_key(again) != failure_key(row["head"])
        end
        break if rows.none? { |row| row["classification"] == "candidate" }
      end
      rows
    end

    def rows_for(relative, base_run, head_run, index, known, source)
      if file_level?(base_run) || file_level?(head_run)
        name = file_level_name(relative, base_run, head_run)
        [build_row(relative, name, side_result(base_run), side_result(head_run), mentions_for(index, name, known, source))]
      else
        names = (base_run.tests.keys | head_run.tests.keys).sort
        names.map { |name|
          build_row(
            relative,
            name,
            base_run.tests[name],
            head_run.tests[name],
            mentions_for(index, name, known, source)
          )
        }
      end
    end

    def file_level?(execution)
      execution.timed_out || execution.file_error || (execution.tests.empty? && execution.exit_code != 0 && !execution.summary)
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
      failed || {
        "status" => "error",
        "error_class" => "RuntimeError",
        "message" => "no tests ran",
        "message_first_line" => "no tests ran",
        "backtrace" => []
      }
    end

    def file_level_result(execution)
      side_result(execution)
    end

    def build_row(relative, name, base_result, head_result, mentions)
      base_result = missing_result if base_result.nil?
      head_result = missing_result if head_result.nil?
      {
        "file" => relative.tr("\\", "/"),
        "name" => name,
        "mentions" => mentions,
        "classification" => classify(base_result, head_result),
        "base" => base_result,
        "head" => head_result
      }
    end

    def classify(base_result, head_result)
      base_pass = base_result["status"] == "pass"
      head_status = head_result["status"]
      if base_pass && %w[fail error timeout].include?(head_status)
        "candidate"
      elsif base_pass && %w[pass skip].include?(head_status)
        "no_signal"
      else
        "fail_on_base"
      end
    end

    def failure_key(result)
      [result["status"], result["error_class"].to_s, result["message_first_line"].to_s].join("\x1f")
    end

    def execute(worktree, relative, normalizer)
      stdout_path = File.join(worktree, ".jitcatch-stdout")
      stderr_path = File.join(worktree, ".jitcatch-stderr")
      cmd = [
        RbConfig.ruby,
        "-I#{File.join(worktree, "lib")}",
        "-I#{worktree}",
        File.join(".jitcatch", relative),
        "-v",
        "--seed",
        "1"
      ]
      status, stdout, stderr, timed_out = run_process(
        cmd,
        chdir: worktree,
        stdout_path: stdout_path,
        stderr_path: stderr_path
      )
      if timed_out
        return Result.new(tests: {}, summary: false, file_error: nil, timed_out: true, exit_code: nil)
      end

      parsed = MinitestParser.parse(stdout, stderr, normalizer: normalizer)
      Result.new(
        tests: parsed["tests"],
        summary: parsed["summary"],
        file_error: parsed["file_error"],
        timed_out: false,
        exit_code: status&.exitstatus
      )
    end

    def run_process(cmd, chdir:, stdout_path:, stderr_path:)
      pid = Process.spawn(child_env, *cmd, chdir: chdir, out: stdout_path, err: stderr_path, pgroup: true, unsetenv_others: true)
      timed_out = false
      status = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      loop do
        waited = Process.wait2(pid, Process::WNOHANG)
        if waited
          status = waited.last
          break
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          timed_out = true
          kill_group(pid)
          begin
            Process.wait2(pid)
          rescue Errno::ECHILD
            nil
          end
          break
        end
        sleep 0.02
      end
      [status, read_text(stdout_path), read_text(stderr_path), timed_out]
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

    def child_env
      env = {}
      %w[PATH HOME USER LOGNAME TMPDIR TEMP TMP LD_LIBRARY_PATH GEM_HOME GEM_PATH].each do |key|
        env[key] = ENV[key] if ENV[key]
      end
      env["LANG"] = "C.UTF-8"
      env["LC_ALL"] = "C.UTF-8"
      env["TERM"] = "dumb"
      env
    end

    def install(worktree)
      dest = File.join(worktree, ".jitcatch")
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      Dir.children(@tests_dir).sort.each do |child|
        FileUtils.cp_r(File.join(@tests_dir, child), dest)
      end
    end

    def candidate_files
      all = Dir.glob("**/*.rb", base: @tests_dir).sort
      named = all.select { |path|
        base = File.basename(path)
        base.match?(/\Atest_.+\.rb\z/) || base.end_with?("_test.rb")
      }
      list = named.empty? ? all : named
      omitted = 0
      if list.size > FILE_CAP
        omitted = list.size - FILE_CAP
        list = list.first(FILE_CAP)
      end
      [list, omitted]
    end

    def known_names(change)
      names = change["methods"].map { |method| method["bare_name"] }
      names += change["entrypoints"].flat_map { |entry|
        entry["methods"].map { |method| SourceIndex.split_qualified(method["name"]).last }
      }
      names.compact.uniq.sort
    end

    # Mentions are taken from the individual test method so a neighbor in the
    # same file does not change this test's tags.
    def mentions_for(index, test_name, known, source)
      method = index.methods.find { |item| item.qualified == test_name }
      text = method ? method.source : source
      known.select { |bare| !bare.empty? && text.match?(/\b#{Regexp.escape(bare)}\b/) }
    end

    def assign_test_ids(rows)
      rows.sort_by! { |row| [row["file"], row["name"]] }
      width = [2, rows.size.to_s.length].max
      rows.each_with_index { |row, index| row["id"] = format("t%0#{width}d", index + 1) }
    end

    def slim_method(method)
      method.reject { |key, _| %w[old_source new_source callsites existing_tests].include?(key) }
    end

    def slim_constant(const)
      const.reject { |key, _| %w[old_source new_source].include?(key) }
    end

    def build_normalizer(roots)
      prefix = RbConfig::CONFIG["prefix"].to_s.sub(%r{/+\z}, "")
      ordered = roots.compact.map { |root| File.expand_path(root).sub(%r{/+\z}, "") }.uniq.sort_by { |item| -item.length }
      lambda do |text|
        out = text.to_s.gsub("\r\n", "\n")
        ordered.each { |root| out = out.gsub("#{root}/", "") }
        out = out.gsub("#{prefix}/", "{ruby}/") unless prefix.empty?
        out
      end
    end

    def pass_result
      { "status" => "pass", "error_class" => nil, "message" => "", "message_first_line" => "", "backtrace" => [] }
    end

    def missing_result
      { "status" => "error", "error_class" => "Missing", "message" => "test did not run", "message_first_line" => "test did not run", "backtrace" => [] }
    end

    def timeout_result
      { "status" => "timeout", "error_class" => "Timeout", "message" => "timeout", "message_first_line" => "timeout", "backtrace" => [] }
    end
  end
end
