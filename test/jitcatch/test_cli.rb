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
      run_out, run_err, run_status = cli("run", "--repo", repo.dir, "--reruns", "0", "base", "HEAD", tests)
      assert_equal 0, run_status, run_err
      assert_includes run_out, "counts "
      assert_includes run_out, "jitcatch run"

      json_run, json_run_err, json_run_status = cli("run", "--json", "--repo", repo.dir, "--reruns", "0", "base", "HEAD", tests)
      assert_equal 0, json_run_status, json_run_err
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
        %w[run --reruns x base HEAD t] => "--reruns requires an integer",
        %w[run --timeout 0 base HEAD t] => "--timeout must be >= 1",
        %w[assess missing.json] => "run json not found: missing.json"
      }.each do |args, message|
        assert_equal ["", "jitcatch: #{message}\n", 1], cli(*args), args.join(" ")
      end
      _out, err, status = cli("context", "--repo", repo.dir, "nope", "HEAD")
      assert_equal 2, status
      assert_match(/\Ajitcatch: /, err)
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

  def cli(*args)
    status = nil
    stdout, stderr = capture_io { status = JitCatch::CLI.start(args) }
    [stdout, stderr, status]
  end
end
