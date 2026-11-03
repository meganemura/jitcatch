# frozen_string_literal: true

require_relative "../test_helper"

class TestRunner < Minitest::Test
  BASE_CALC = <<~RUBY
    class Calc
      def add(a, b)
        a + b
      end

      def double(n)
        n * 2
      end

      def total(n)
        double(add(n, 1))
      end

      def label
        "ok"
      end
    end
  RUBY

  HEAD_CALC = <<~RUBY
    class Calc
      def add(a, b, c)
        a + b + c
      end

      def double(n)
        n * 2 + 1
      end

      def total(n)
        double(add(n, 1))
      end

      def label
        "ok"
      end
    end
  RUBY

  def test_classifies_signal_flakes_and_signature_changes
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.write("test/test_calc.rb", "def test_double; double; end\n")
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")

      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "label_test.rb" => candidate_source("LabelTest", "test_label", 'assert_equal "ok", Calc.new.label'),
        "double_test.rb" => candidate_source("DoubleTest", "test_double", "assert_equal 4, Calc.new.double(2)"),
        "add_arity_test.rb" => candidate_source("AddArityTest", "test_two_args", "assert_equal 3, Calc.new.add(1, 2)"),
        "new_add_test.rb" => candidate_source("NewAddTest", "test_three_args", "assert_equal 6, Calc.new.add(1, 2, 3)"),
        "total_test.rb" => candidate_source("TotalTest", "test_total", "assert_equal 4, Calc.new.total(1)")
      })

      before = repo.git("worktree", "list", "--porcelain")
      doc = execute(repo, tests)
      assert_equal before, repo.git("worktree", "list", "--porcelain")
      again = execute(repo, tests)
      assert_equal JitCatch::Render.run_text(doc), JitCatch::Render.run_text(again)
      text = JitCatch::Render.run_text(doc)
      refute_match(%r{/tmp/}, text)
      refute_match(/Finished in/, text)
      refute_match(/\d{4}-\d{2}-\d{2}/, text)

      assert_equal({
        "generated" => 5,
        "no_signal" => 1,
        "fail_on_base" => 1,
        "candidates" => 3,
        "flaky" => 0,
        "discarded" => 2,
        "reported" => 1
      }, doc["counts"])

      by_name = doc["tests"].to_h { |test| [test["name"], test] }
      assert_equal "no_signal", by_name["LabelTest#test_label"]["disposition"]
      assert_equal "fail_on_base", by_name["NewAddTest#test_three_args"]["disposition"]
      assert_equal "reported", by_name["DoubleTest#test_double"]["disposition"]
      assert_includes by_name["DoubleTest#test_double"]["tags"], "touches:changed_method"
      assert_includes by_name["DoubleTest#test_double"]["head"]["message"], "Actual: 5"
      assert_equal "discarded", by_name["AddArityTest#test_two_args"]["disposition"]
      assert_includes by_name["AddArityTest#test_two_args"]["tags"], "discard:signature_change"
      assert_equal "discarded", by_name["TotalTest#test_total"]["disposition"]
      assert_includes by_name["TotalTest#test_total"]["tags"], "discard:signature_change"
      assert_includes by_name["TotalTest#test_total"]["tags"], "touches:unchanged_caller"
      assert_equal %w[bare_name callsites_omitted change end_line file id kind name new_end new_start
        old_end old_start reachable_from signature start_line via_constant visibility],
        doc["methods"].flat_map(&:keys).uniq.sort

      json =JitCatch::Render.dump(JitCatch::Render.run_json(doc))
      path = File.join(repo.dir, "run.json")
      File.write(path, json)
      assessed = JitCatch::Assessor.apply(JSON.parse(File.read(path)))
      assert_equal doc["counts"], assessed["counts"]
    end
  end

  def test_drops_a_test_that_does_not_fail_again_on_head
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; def self.ok; true; end; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  def self.ok\n    true\n  end\nend\n")
      repo.commit("Reformat only.", date: "2026-02-12T00:00:00Z")

      marker = File.join(repo.dir, "marker")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "flip_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "flag"

          class FlipTest < Minitest::Test
            def test_flip
              path = #{marker.inspect} + "-" + File.basename(Dir.pwd)
              n = File.exist?(path) ? Integer(File.read(path)) : 0
              File.write(path, (n + 1).to_s)
              flunk "flip" if n.zero? && File.basename(Dir.pwd) == "head"
            end
          end
        RUBY
      })
      doc = execute(repo, tests, reruns: 2)
      assert_equal 1, doc["counts"]["generated"]
      assert_equal 1, doc["counts"]["flaky"]
      assert_equal 0, doc["counts"]["candidates"]
      assert_equal "flaky", doc["tests"].fetch(0)["disposition"]
      assert_equal [{ "status" => "pass", "error_class" => nil, "message_first_line" => "", "message" => "" }], doc["tests"].fetch(0)["reruns"]
      assert_includes JitCatch::Render.run_text(doc), "    rerun 1: pass\n"
    end
  end

  def test_an_object_address_in_the_message_does_not_make_a_rerun_disagree
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag\n  class Error < StandardError; end\n  def self.kind = Error\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  class Error < StandardError; end\n  def self.kind = Class.new(Error)\nend\n")
      repo.commit("Build a new class.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "kind_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "flag"

          class KindTest < Minitest::Test
            def test_kind
              assert_equal Flag::Error, Flag.kind
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      row = doc["tests"].fetch(0)
      assert_equal "reported", row["disposition"], row["reruns"].inspect
      assert_match(/Actual: #<Class:0x\h+>/, row["head"]["message"])
    end
  end

  def test_a_rerun_whose_actual_value_moves_is_flaky
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; def self.ok; true; end; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  def self.ok\n    true\n  end\nend\n")
      repo.commit("Reformat only.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "count_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "flag"

          class CountTest < Minitest::Test
            def test_count
              n = File.exist?("count") ? Integer(File.read("count")) : 0
              File.write("count", (n + 1).to_s)
              assert_equal 0, File.basename(Dir.pwd) == "head" ? n + 1 : n
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      row = doc["tests"].fetch(0)
      assert_equal "flaky", row["disposition"], row["reruns"].inspect
      assert_includes JitCatch::Render.run_text(doc), "    rerun 1: fail Minitest::Assertion Actual: 2\n"
    end
  end

  def test_keeps_a_failure_whose_message_names_a_new_temp_directory_each_run
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "trace_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "tmpdir"
          require "calc"

          class TraceTest < Minitest::Test
            def test_trace
              Dir.mktmpdir("quint") do |dir|
                path = File.join(dir, "trace_0.itf.json")
                assert_equal 4, Calc.new.double(2), "replay of \#{path} disagreed"
              end
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      row = doc["tests"].fetch(0)
      assert_equal "reported", row["disposition"]
      assert_equal 2, row["reruns"].size
      assert_equal %w[fail fail], row["reruns"].map { |rerun| rerun["status"] }
      assert_match(%r{replay of /.+/quint.+/trace_0\.itf\.json disagreed}, row["reruns"].fetch(0)["message_first_line"])
    end
  end

  def test_discards_a_name_error_on_a_removed_nested_class
    with_repo do |repo|
      repo.write("lib/model.rb", "class Model\n  class Unsupported < StandardError; end\n\n  def check(op)\n    raise Unsupported, op unless op == \"+\"\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/model.rb", "class Model\n  def check(op)\n    raise ArgumentError, op unless op == \"+\"\n  end\nend\n")
      repo.commit("Raise ArgumentError.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "model_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "model"

          class ModelTest < Minitest::Test
            def test_unsupported
              assert_raises(Model::Unsupported) { Model.new.check("*") }
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      row = doc["tests"].fetch(0)
      assert_equal "NameError", row["head"]["error_class"]
      assert_equal "discarded", row["disposition"]
      assert_includes row["tags"], "discard:signature_change"
    end
  end

  def test_discards_a_new_required_keyword_raised_inside_assert_raises
    with_repo do |repo|
      repo.write("lib/trace.rb", "class Trace\n  class Unsupported < StandardError; end\n\n  def self.replay(path)\n    raise Unsupported, path\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/trace.rb", "class Trace\n  class Unsupported < StandardError; end\n\n  def self.replay(path, steps:)\n    raise Unsupported, path\n  end\nend\n")
      repo.commit("Take a step count.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "trace_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "trace"

          class TraceTest < Minitest::Test
            def test_unsupported
              assert_raises(Trace::Unsupported) { Trace.replay("x.itf.json") }
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      row = doc["tests"].fetch(0)
      assert_match(/missing keyword: :steps/, row["head"]["message"])
      assert_equal "discarded", row["disposition"]
      assert_includes row["tags"], "discard:signature_change"
    end
  end

  def test_a_test_that_names_a_changed_constant_mentions_it
    with_repo do |repo|
      repo.write("lib/geo.rb", "module Geo\n  SCALE = 2\n  Point = Struct.new(:x) do\n    def scaled\n      x * SCALE\n    end\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/geo.rb", "module Geo\n  SCALE = 3\n  Point = Struct.new(:x) do\n    def scaled\n      x * SCALE\n    end\n  end\nend\n")
      repo.commit("Scale by three.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "geo_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "geo"

          class GeoTest < Minitest::Test
            def test_scale
              assert_equal 2, Geo::SCALE
            end

            def test_point
              assert_equal 4, Geo::Point.new(2).scaled
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      assert_equal [["Geo::Point#scaled", "affected"]], doc["methods"].map { |method| method.values_at("name", "change") }
      by_name = doc["tests"].to_h { |test| [test["name"], test] }
      assert_equal ["SCALE"], by_name["GeoTest#test_scale"]["mentions"]
      assert_includes by_name["GeoTest#test_scale"]["tags"], "touches:changed_constant"
      assert_equal ["scaled"], by_name["GeoTest#test_point"]["mentions"]
      assert_includes by_name["GeoTest#test_point"]["tags"], "touches:changed_method"
      refute_includes by_name["GeoTest#test_point"]["tags"], "touches:changed_constant"
    end
  end

  def test_reruns_judge_only_candidates_and_run_every_rerun
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      counts = File.join(repo.dir, "counts")
      FileUtils.mkdir_p(counts)
      counter = <<~RUBY
        def head_run(name)
          return 0 unless Dir.pwd.end_with?("/head")

          path = File.join(#{counts.inspect}, name)
          n = File.exist?(path) ? Integer(File.read(path)) + 1 : 1
          File.write(path, n.to_s)
          n
        end
      RUBY
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "mixed_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"
          #{counter}
          class MixedTest < Minitest::Test
            def test_stable
              assert_equal 4, Calc.new.double(2)
            end

            def test_quiet_then_loud
              flunk "loud" if head_run("quiet") > 1
            end
          end
        RUBY
        "late_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"
          #{counter}
          class LateTest < Minitest::Test
            def test_late_flip
              flunk "late" if head_run("late").between?(1, 2)
            end
          end
        RUBY
        "quiet_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "calc"
          #{counter}
          class QuietTest < Minitest::Test
            def test_quiet
              head_run("only")
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      dispositions = doc["tests"].to_h { |test| [test["name"], test["disposition"]] }
      assert_equal({ "LateTest#test_late_flip" => "flaky", "MixedTest#test_quiet_then_loud" => "no_signal",
                     "MixedTest#test_stable" => "reported", "QuietTest#test_quiet" => "no_signal" }, dispositions)
      assert_equal %w[3 3 1], %w[late quiet only].map { |name| File.read(File.join(counts, name)) }
    end
  end

  def test_a_test_only_head_defines_and_a_file_that_stops_loading_on_head
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC.sub("  def label", "  def triple(n)\n    n * 3\n  end\n\n  def label"))
      repo.commit("Add triple.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "triple_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"

          class TripleTest < Minitest::Test
            if Calc.method_defined?(:triple)
              def test_triple
                assert_equal 6, Calc.new.triple(2)
              end
            end

            if Calc.instance_method(:add).arity == 2
              def test_add_two
                assert_equal 3, Calc.new.add(1, 2)
              end
            end
          end
        RUBY
        "broken_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"
          raise "double moved" unless Calc.new.double(2) == 4

          class BrokenTest < Minitest::Test
            def test_already_failing
              flunk "fails on base"
            end
          end
        RUBY
        "guard_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "calc"
          raise "double moved" unless Calc.new.double(2) == 4

          class GuardTest < Minitest::Test
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 1)

      rows = doc["tests"].map { |test| [test["name"], test["disposition"], test["base"]["status"], test["head"]["status"]] }
      assert_equal [
        ["TripleTest#test_add_two", "reported", "pass", "error"],
        ["TripleTest#test_triple", "fail_on_base", "error", "pass"],
        ["broken_test.rb#load", "fail_on_base", "fail", "error"],
        ["guard_test.rb#load", "reported", "pass", "error"]
      ], rows.sort
      assert_match(/\A\.jitcatch\/guard_test\.rb:3:in .<main>.: double moved \(RuntimeError\)\z/, doc["tests"].find { |test| test["name"] == "guard_test.rb#load" }["head"]["message"])
      assert_equal 0, doc["test_files_omitted"]
    end
  end

  def test_messages_keep_utf8_and_lose_worktree_and_ruby_paths
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "words_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "json"
          require "calc"

          class WordsTest < Minitest::Test
            def test_word
              assert_equal "caf\\u00e9", Calc.new.double(2) == 4 ? "caf\\u00e9" : "cafe"
            end

            def test_file
              assert_equal "x", __FILE__
            end

            def test_parse
              JSON.parse("{") unless Calc.new.double(2) == 4
            end

            def test_path
              assert_equal "x", File.expand_path("lib/calc.rb")
            end

            def test_lib_frame
              raise "moved" unless Calc.new.double(2) == 4
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      by_name = doc["tests"].to_h { |test| [test["name"], test] }
      assert_includes JitCatch::Render.run_text(doc), "Actual: \"cafe\""
      assert_includes JitCatch::Render.dump(doc), "caf\u00e9"
      assert_equal "Expected: \"x\"\n  Actual: \".jitcatch/words_test.rb\"", by_name["WordsTest#test_file"]["head"]["message"]
      assert_equal "{ruby}/", by_name["WordsTest#test_parse"]["head"]["backtrace"].fetch(0)["file"][0, 7]
      assert_includes by_name["WordsTest#test_path"]["head"]["message"], "+\"{worktree}/lib/calc.rb\"", "a rewritten worktree root stays visible"
      assert_includes by_name["WordsTest#test_word"]["head"]["message"], "café"
      frames = doc["tests"].flat_map { |test| [test["base"], test["head"]] }.flat_map { |side| side["backtrace"] }.map { |frame| frame["file"] }
      assert_includes frames, ".jitcatch/words_test.rb"
      assert_empty frames.select { |file| file.start_with?("/") }
    end
  end

  def test_keeps_a_long_failure_whose_temp_directory_name_changes_length
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "long_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "tmpdir"
          require "calc"

          class LongTest < Minitest::Test
            def test_long
              count = File.join(__dir__, "runs")
              runs = File.exist?(count) ? File.read(count).to_i + 1 : 0
              File.write(count, runs.to_s)
              Dir.mktmpdir("q" + "x" * runs) do |dir|
                assert Calc.new.double(2) == 4, "\#{dir}/a \#{"y" * 200}"
              end
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      row = doc["tests"].fetch(0)
      assert_equal "reported", row["disposition"]
      assert_equal %w[fail fail], row["reruns"].map { |rerun| rerun["status"] }
    end
  end

  def test_the_run_does_not_depend_on_the_worker_count
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "a_double_test.rb" => candidate_source("DoubleTest", "test_double", "assert_equal 4, Calc.new.double(2)"),
        "b_add_test.rb" => candidate_source("AddTest", "test_add", "assert_equal 3, Calc.new.add(1, 2)"),
        "c_path_test.rb" => candidate_source("PathTest", "test_path", "assert_equal 4, Calc.new.double(2), File.expand_path(__dir__)"),
        "d_load_test.rb" => "require \"minitest/autorun\"\nrequire \"calc\"\nCalc.new.add(1, 2)\n",
        "e_pass_test.rb" => candidate_source("PassTest", "test_label", "assert Calc.new.label")
      })

      docs = [1, 3].map { |workers| JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 1, workers: workers) }

      assert_equal docs[0], docs[1]
      assert_equal %w[candidate candidate candidate candidate no_signal], docs[0]["tests"].map { |test| test["classification"] }
      assert_raises(JitCatch::UsageError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, workers: 0) }
    end
  end

  # Forty files cost eighty Ruby processes, so the cap is lowered to two
  # here and checked to be forty on its own.
  def test_runs_at_most_forty_files
    assert_equal 40, JitCatch::Runner::FILE_CAP
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, %w[f03 f01 f02].to_h { |name| [format("%s_test.rb", name), candidate_source(name.upcase, "test_#{name}", "assert true")] })

      doc = with_file_cap(2) { execute(repo, tests) }

      assert_equal 1, doc["test_files_omitted"]
      assert_equal %w[f01_test.rb f02_test.rb], doc["tests"].map { |test| test["file"] }
    end
  end

  def test_discards_head_timeout
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; def self.ok; true; end; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      head_runs = File.join(repo.dir, "head-runs")
      write_tests(tests, {
        "slow_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "flag"

          class SlowTest < Minitest::Test
            def test_slow
              if Dir.pwd.end_with?("/head")
                File.write(#{head_runs.inspect}, "x", mode: "a")
                sleep 60
              end
              assert Flag.ok
            end
          end
        RUBY
      })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      doc = execute(repo, tests, timeout: 1, reruns: 2)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 30, "the timed-out process was not killed"
      assert_equal "x", File.read(head_runs), "a timeout is not rerun"
      assert_equal 1, doc["counts"]["generated"]
      assert_equal 1, doc["counts"]["discarded"]
      assert_equal 0, doc["counts"]["reported"]
      row = doc["tests"].fetch(0)
      assert_equal "discarded", row["disposition"]
      assert_includes row["tags"], "discard:timeout"
      assert_equal "pass", row["base"]["status"]
      assert_equal "timeout", row["head"]["status"]
      assert_equal "slow_test.rb#timeout", row["name"]
      assert_includes JitCatch::Render.run_text(doc), "slow_test.rb#timeout slow_test.rb\n    hint: head timed out after 1s; raise --timeout if the file needs longer\n"
    end
  end

  def test_a_minitest_spec_file_runs_as_minitest_and_keeps_its_spaced_names
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Change double.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "calc_spec.rb" => <<~RUBY
          require "minitest/autorun"
          require "calc"

          describe Calc do
            it "doubles two" do
              _(Calc.new.double(2)).must_equal 4
            end

            it "labels" do
              _(Calc.new.label).must_equal "ok"
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      rows = doc["tests"].to_h { |test| [test["name"], [test["disposition"], test["rerun"]]] }
      assert_equal({
        "Calc#test_0001_doubles two" => ["reported", "ruby -Ilib -I. {tests}/calc_spec.rb -n 'Calc#test_0001_doubles two'"],
        "Calc#test_0002_labels" => ["no_signal", "ruby -Ilib -I. {tests}/calc_spec.rb -n Calc#test_0002_labels"]
      }, rows)
      assert_equal "Expected: 4", doc["tests"].fetch(0)["head"]["message_first_line"]
    end
  end

  def test_runs_named_files_and_tags_each_test_by_its_own_method
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.write("lib/extra.rb", "module Extra; end\n")
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      FileUtils.rm(File.join(repo.dir, "lib/extra.rb"))
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")

      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "helper.rb" => "raise 'helper.rb is not a test file'\n",
        "calc_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"

          class CalcTest < Minitest::Test
            def test_ruby
              assert_equal 2, 1 + 1
            end

            def test_double
              assert_equal 4, Calc.new.double(2)
            end
          end
        RUBY
        "test_extra.rb" => <<~RUBY
          require "minitest/autorun"
          require "extra"

          class ExtraTest < Minitest::Test
            def test_loads
              assert Extra
            end
          end
        RUBY
      })
      doc = execute(repo, tests)
      rows = doc["tests"].map { |test| test.values_at("id", "file", "name", "mentions", "classification", "disposition") }
      assert_equal [
        ["t01", "calc_test.rb", "CalcTest#test_double", ["double"], "candidate", "reported"],
        ["t02", "calc_test.rb", "CalcTest#test_ruby", [], "no_signal", "no_signal"],
        ["t03", "test_extra.rb", "test_extra.rb#load", ["Extra"], "candidate", "discarded"]
      ], rows
      assert_equal ["pass", "LoadError"], doc["tests"][2].values_at("base", "head").map { |side| side["error_class"] || side["status"] }
      assert_raises(JitCatch::UsageError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", File.join(repo.dir, "nope")) }
    end
  end

  def test_mentions_follow_same_file_helpers_and_read_new_as_initialize
    with_repo do |repo|
      repo.write("lib/price.rb", "class Price\n  def initialize(cents)\n    @cents = cents\n  end\n\n  def cents\n    @cents\n  end\n\n  def doubled\n    @cents * 2\n  end\nend\n\nclass Box\n  def size\n    1\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/price.rb", "class Price\n  def initialize(cents)\n    @cents = cents + 1\n  end\n\n  def cents\n    @cents\n  end\n\n  def doubled\n    @cents * 3\n  end\nend\n\nclass Box\n  def size\n    2\n  end\nend\n")
      repo.commit("Rework price.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "price_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "price"

          class PriceTest < Minitest::Test
            def test_doubled_through_a_helper
              assert_equal 6, doubled_of(3)
            end

            def test_new_keeps_the_cents
              assert_equal 3, Price.new(3).cents
            end

            def test_box_new_is_not_price_new
              assert_equal 1, Box.new.size
            end

            private

            def doubled_of(amount)
              build(amount).doubled
            end

            def build(amount, depth = 0)
              depth.zero? ? build(amount, depth + 1) : Price.new(amount)
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("mentions", "method_id")] }
      assert_equal [%w[doubled initialize], ids["Price#doubled"]], rows["PriceTest#test_doubled_through_a_helper"]
      assert_equal [%w[cents initialize], ids["Price#initialize"]], rows["PriceTest#test_new_keeps_the_cents"]
      assert_equal [%w[size], ids["Box#size"]], rows["PriceTest#test_box_new_is_not_price_new"]
      doc["tests"].each { |test| assert_includes test["tags"], "touches:changed_method", test["name"] }
    end
  end

  def test_a_word_in_a_string_or_a_comment_is_not_a_mention
    with_repo do |repo|
      repo.write("lib/job.rb", "class B\n  def run\n    1\n  end\nend\n\nmodule Z\n  def self.run_text\n    \"x run\"\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/job.rb", "class B\n  def run\n    2\n  end\nend\n\nmodule Z\n  def self.run_text\n    \"y run\"\n  end\nend\n")
      repo.commit("Rework jobs.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "job_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "job"

          class JobTest < Minitest::Test
            def test_text
              # B#run is not called here.
              assert_equal "x run", Z.run_text
            end

            def test_symbol_and_constant
              assert_equal 1, B.new.public_send(:run)
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("mentions", "method_id")] }
      assert_equal [%w[run_text], ids["Z.run_text"]], rows["JobTest#test_text"]
      assert_equal [%w[run], ids["B#run"]], rows["JobTest#test_symbol_and_constant"]
    end
  end

  def test_the_base_and_head_runs_of_a_file_overlap
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "meet_test.rb" => <<~RUBY
          require "minitest/autorun"

          class MeetTest < Minitest::Test
            def test_the_other_side_is_running
              dir = ENV.fetch("MEET_DIR")
              File.write(File.join(dir, Process.pid.to_s), "")
              deadline = Time.now + 5
              sleep 0.01 until Dir.children(dir).size >= 2 || Time.now > deadline
              assert_equal 2, Dir.children(dir).size
            end
          end
        RUBY
      })

      Dir.mktmpdir("jitcatch-meet-") do |meet|
        ENV["MEET_DIR"] = meet
        doc = execute(repo, tests, env: ["MEET_DIR"])
        assert_equal [%w[pass pass]], doc["tests"].map { |test| [test.dig("base", "status"), test.dig("head", "status")] }
      ensure
        ENV.delete("MEET_DIR")
      end
    end
  end

  def test_candidate_process_gets_only_the_allowlisted_environment
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; def self.ok; true; end; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      gems = [Gem.default_dir, [Gem.default_dir, File.join(repo.dir, "more-gems")].join(File::PATH_SEPARATOR)]
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "env_test.rb" => <<~RUBY
          require "minitest/autorun"

          class EnvTest < Minitest::Test
            def test_parent_only_variables_are_absent
              assert_equal [nil, nil, nil, nil], ENV.values_at("RUBYOPT", "CI", "HEGEL_SEED", "JITCATCH_PARENT_ONLY")
            end

            def test_gem_locations_are_kept
              assert_equal #{gems.inspect}, ENV.values_at("GEM_HOME", "GEM_PATH")
            end

            def test_named_variables_pass_and_the_locale_is_fixed
              assert_equal ["yes", nil, "C.UTF-8", "C.UTF-8", "dumb", nil],
                ENV.values_at("JITCATCH_PASS", "JITCATCH_UNSET", "LANG", "LC_ALL", "TERM", "BUNDLE_GEMFILE")
            end
          end
        RUBY
      })
      parent = { "RUBYOPT" => "-W:no-deprecated", "CI" => "1", "HEGEL_SEED" => "7", "JITCATCH_PARENT_ONLY" => "x",
                 "GEM_HOME" => gems[0], "GEM_PATH" => gems[1], "JITCATCH_PASS" => "yes", "LANG" => "en_US.UTF-8",
                 "BUNDLE_GEMFILE" => File.join(repo.dir, "Gemfile") }
      saved = ENV.to_h.slice(*parent.keys)
      begin
        ENV.update(parent)
        doc = execute(repo, tests, env: %w[JITCATCH_UNSET JITCATCH_PASS])
      ensure
        parent.each_key { |key| ENV.delete(key) }
        ENV.update(saved)
      end
      assert_equal %w[pass pass pass], doc["tests"].map { |test| test["base"]["status"] }, doc["tests"].map { |test| test["base"]["message"] }.join("\n")
      assert_equal %w[JITCATCH_PASS JITCATCH_UNSET], doc["env"]
      assert_equal({ "base" => { "status" => "none", "message" => "" }, "head" => { "status" => "none", "message" => "" } }, doc["bundle"])
    end
  end

  def test_each_side_loads_the_gems_its_own_gemfile_locks
    with_repo do |repo|
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "minitest"\ngem "dep", path: "vendor/dep"\n))
      repo.write("vendor/dep/dep.gemspec", dep_gemspec("1.0.0"))
      repo.write("vendor/dep/lib/dep.rb", %(module Dep\n  VERSION = "1.0.0"\nend\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("vendor/dep/dep.gemspec", dep_gemspec("2.0.0"))
      repo.write("vendor/dep/lib/dep.rb", %(module Dep\n  VERSION = "2.0.0"\nend\n))
      repo.commit("Bump dep to 2.0.0.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "dep_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "dep"

          class DepTest < Minitest::Test
            def test_dep_is_one
              assert_equal ["1.0.0", "1.0.0"], [Dep::VERSION, Gem.loaded_specs.fetch("dep").version.to_s]
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      assert_equal({ "base" => { "status" => "ok", "message" => "" }, "head" => { "status" => "ok", "message" => "" } }, doc["bundle"])
      row = doc["tests"].fetch(0)
      assert_equal ["reported", "pass", "fail"], [row["disposition"], row["base"]["status"], row["head"]["status"]], row["head"]["message"]
      assert_includes JitCatch::Render.run_text(doc), "timeout_s 10\nbundle base ok\nbundle head ok\ntests:\n"
    end
  end

  def test_reports_a_side_whose_locked_gems_are_not_installed
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "jitcatch_absent_gem", "9.9.9"\n))
      repo.commit("Add a Gemfile.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      doc = execute(repo, tests)

      message = "Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems."
      assert_equal({ "base" => { "status" => "none", "message" => "" }, "head" => { "status" => "failed", "message" => message } }, doc["bundle"])
      assert_includes JitCatch::Render.run_text(doc), "timeout_s 10\nbundle head failed: #{message}\ntests:\n"
    end
  end

  def test_reports_a_bundle_that_does_not_list_minitest
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.write("Gemfile", %(source "https://rubygems.org"\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\nend\n")
      repo.commit("Reformat.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      doc = execute(repo, tests)

      missing = { "status" => "failed", "message" => 'minitest is not in the bundle: add gem "minitest" to the Gemfile' }
      assert_equal({ "base" => missing, "head" => missing }, doc["bundle"])
      assert_equal "LoadError", doc["tests"].fetch(0)["head"]["error_class"]
    end
  end

  def dep_gemspec(version)
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "dep"
        spec.version = "#{version}"
        spec.summary = "dep"
        spec.authors = ["jittest"]
        spec.files = ["lib/dep.rb"]
      end
    RUBY
  end

  def with_file_cap(cap)
    saved = JitCatch::Runner::FILE_CAP
    JitCatch::Runner.send(:remove_const, :FILE_CAP)
    JitCatch::Runner.const_set(:FILE_CAP, cap)
    yield
  ensure
    JitCatch::Runner.send(:remove_const, :FILE_CAP)
    JitCatch::Runner.const_set(:FILE_CAP, saved)
  end

  def execute(repo, tests, reruns: 0, timeout: 10, env: [])
    raw = JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: reruns, timeout: timeout, env: env)
    JitCatch::Assessor.apply(raw)
  end

  def candidate_source(class_name, name, assertion)
    <<~RUBY
      require "minitest/autorun"
      require "calc"

      class #{class_name} < Minitest::Test
        def #{name}
          #{assertion}
        end
      end
    RUBY
  end
end
