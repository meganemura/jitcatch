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
      assert_equal 0, status.exitstatus, stderr
      assert_equal "", stderr
      assert_includes stdout, "jitcatch context"
      assert_includes stdout, "Box::LIMIT"
      json, json_err, json_status = cli("context", "--json", "--repo", repo.dir, "base", "HEAD")
      assert_equal 0, json_status.exitstatus, json_err
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
      assert_equal 0, run_status.exitstatus, run_err
      assert_includes run_out, "counts "
      assert_includes run_out, "jitcatch run"

      json_run, json_run_err, json_run_status = cli("run", "--json", "--repo", repo.dir, "--reruns", "0", "base", "HEAD", tests)
      assert_equal 0, json_run_status.exitstatus, json_run_err
      report = File.join(repo.dir, "run.json")
      File.write(report, json_run)
      assessed, assessed_err, assessed_status = cli("assess", "--json", report)
      assert_equal 0, assessed_status.exitstatus, assessed_err
      assert_equal JSON.parse(json_run)["counts"], JSON.parse(assessed)["counts"]

      usage, _err, usage_status = cli("nope")
      assert_equal 1, usage_status.exitstatus
      assert_equal "", usage
    end
  end

  def test_help
    stdout, stderr, status = cli
    assert_equal 0, status.exitstatus
    assert_equal "", stderr
    assert_includes stdout, "never calls an LLM"
  end

  def cli(*args)
    bin = File.expand_path("../../bin/jitcatch", __dir__)
    Open3.capture3(RbConfig.ruby, bin, *args)
  end
end
