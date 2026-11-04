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
        "discarded" => 1,
        "reported" => 2
      }, doc["counts"])

      by_name = doc["tests"].to_h { |test| [test["name"], test] }
      assert_equal "no_signal", by_name["LabelTest#test_label"]["disposition"]
      assert_equal "fail_on_base", by_name["NewAddTest#test_three_args"]["disposition"]
      assert_equal "reported", by_name["DoubleTest#test_double"]["disposition"]
      assert_includes by_name["DoubleTest#test_double"]["tags"], "touches:changed_method"
      assert_includes by_name["DoubleTest#test_double"]["head"]["message"], "Actual: 5"
      assert_equal "discarded", by_name["AddArityTest#test_two_args"]["disposition"]
      assert_includes by_name["AddArityTest#test_two_args"]["tags"], "discard:signature_change"
      # The unchanged total still calls add with two arguments, so head is
      # broken and the row is reported.
      assert_equal "reported", by_name["TotalTest#test_total"]["disposition"]
      assert_includes by_name["TotalTest#test_total"]["tags"], "caller:unchanged:lib/calc.rb:11"
      assert_includes by_name["TotalTest#test_total"]["tags"], "touches:unchanged_caller"
      assert_equal %w[bare_name builders callbacks caller_depths callsites_omitted change dynamic_callers end_line file forwards_to_added id kind moved_from name new_end new_start
        old_end old_start reachable_from reached_by run_by signature start_line via_constant visibility],
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

  # A record's inspect, as RSpec's have_attributes prints it, names the
  # time it was saved, which is new on every run.
  def test_a_saved_time_in_the_message_does_not_make_a_rerun_disagree
    with_repo do |repo|
      repo.write("lib/stamp.rb", "module Stamp\n  def self.state = \"pending\"\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/stamp.rb", "module Stamp\n  def self.state = \"draft\"\nend\n")
      repo.commit("Open as a draft.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "stamp_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "stamp"

          class StampTest < Minitest::Test
            def test_state
              record = { state: Stamp.state, created_at: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.%N +0000") }
              assert_equal "pending", record[:state], record.inspect
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      row = doc["tests"].fetch(0)
      assert_equal "reported", row["disposition"], row["reruns"].inspect
      assert_match(/created_at(?:: |=>)"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \+0000"/, row["head"]["message"])
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

  def test_an_assert_raises_row_names_the_class_and_message_that_came
    with_repo do |repo|
      repo.write("lib/a.rb", %(module A; def self.f = raise(KeyError, "k"); end\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", %(module A; def self.f = raise(ArgumentError, "wrapped k"); end\n))
      repo.commit("Wrap the key error.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "a_test.rb" => candidate_source("ATest", "test_f_raises_key_error", "assert_raises(KeyError) { A.f }").sub('"calc"', '"a"') })

      text = JitCatch::Render.run_text(execute(repo, tests))

      assert_includes text, <<~ROW.gsub(/^/, "    ")
        [KeyError] exception expected, not
        Class: <ArgumentError>
        Message: <"wrapped k">
        rerun: ruby -Ilib -I. candidates/a_test.rb -n ATest#test_f_raises_key_error
      ROW
    end
  end

  # The run loads a candidate from `.jitcatch/` at the checkout's root, and
  # the rerun line loads it from TESTS_DIR, so a require_relative that
  # leaves TESTS_DIR names one file in the run and another in the rerun
  # unless TESTS_DIR sits at the root. The printed line then passes where
  # the row says head failed.
  def test_warns_of_a_require_relative_that_the_rerun_line_resolves_elsewhere
    with_repo do |repo|
      repo.write("lib/a.rb", "module A; def self.f = 1; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", "module A; def self.f = 2; end\n")
      repo.commit("Return 2.", date: "2026-02-12T00:00:00Z")
      source = { "a_test.rb" => %(require "minitest/autorun"\nrequire_relative "../lib/a"\nrequire_relative "helper"\n\nclass ATest < Minitest::Test\n  def setup = require_relative(File.join(__dir__, "helper"))\n  def test_f = assert_equal(1, A.f)\nend\n), "helper.rb" => "" }
      Dir.mktmpdir("jitcatch-outside-") do |outside|
        tests = File.join(outside, "catch")
        write_tests(tests, source)
        FileUtils.mkdir_p(File.join(outside, "lib"))
        File.write(File.join(outside, "lib", "a.rb"), "module A; def self.f = 1; end\n")
        write_tests(File.join(repo.dir, "candidates"), source)

        doc = execute(repo, tests)
        inside = execute(repo, File.join(repo.dir, "candidates"))

        from_root = Pathname(File.realpath(outside)).relative_path_from(Pathname(File.realpath(repo.dir))).to_s
        warning = "a_test.rb:2 require_relative \"../lib/a\" loads lib/a.rb in the run but #{from_root}/lib/a.rb from the rerun line, so that line may not reproduce the row. Load the repository's code with `require` and the rerun line's -I, or put TESTS_DIR directly under the repository root."
        unsettled = "a_test.rb:6 require_relative names a path the source does not settle, so jitcatch cannot tell whether the run and the rerun line load the same file. Load the repository's code with `require` and the rerun line's -I, or put TESTS_DIR directly under the repository root."
        assert_equal [warning, unsettled], doc["warnings"]
        assert_includes JitCatch::Render.run_text(doc), "warning: #{warning}\n"
        assert_equal [], inside["warnings"]
        assert_equal "fail", doc["tests"].fetch(0)["head"]["status"]
        _output, status = Open3.capture2e(*Shellwords.split(doc["tests"].fetch(0)["rerun"]), chdir: repo.dir)
        assert status.success?, "the rerun line loads the copy of lib/a.rb beside TESTS_DIR"
      end
    end
  end

  # The rerun line runs from the repository root as printed, so a tests
  # directory is named by its path from that root, outside the repository
  # too: a machine's own directories stay out of a quoted line. The
  # frames name the same path, and the assessor still reads them as the
  # test's own.
  def test_a_rerun_line_names_the_tests_directory_it_runs_from_the_root
    with_repo do |repo|
      repo.write("lib/a.rb", "module A; def self.f = 1; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", "module A; def self.f = 2; end\n")
      repo.commit("Return 2.", date: "2026-02-12T00:00:00Z")
      source = { "a_test.rb" => candidate_source("ATest", "test_f", "assert_equal 1, A.f").sub('"calc"', '"a"') }
      inside = File.join(repo.dir, "cand dir")
      write_tests(inside, source)
      Dir.mktmpdir("jitcatch-outside-") do |outside|
        write_tests(outside, source)

        rows = [inside, outside].map { |tests| execute(repo, tests)["tests"].fetch(0) }
        lines = rows.map { |row| row["rerun"] }
        from_root = Pathname(File.realpath(outside)).relative_path_from(Pathname(File.realpath(repo.dir))).to_s

        assert_match %r{\A(\.\./)+}, from_root
        assert_equal ["ruby -Ilib -I. 'cand dir/a_test.rb' -n ATest#test_f", "ruby -Ilib -I. #{from_root}/a_test.rb -n ATest#test_f"], lines
        assert_equal [["cand dir/a_test.rb", 6], ["#{from_root}/a_test.rb", 6]], rows.map { |row| row["head"]["backtrace"].last.values_at("file", "line") }
        lines.each do |line|
          output, status = Open3.capture2e(*Shellwords.split(line), chdir: repo.dir)
          refute status.success?, output
          assert_includes output, "Expected: 1"
        end
      end
    end
  end

  def test_a_removed_method_that_unchanged_code_still_calls_is_reported
    with_repo do |repo|
      inherited_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "b_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "b"

          class BTest < Minitest::Test
            def test_m
              assert_equal 4, B.new.m(2)
            end

            def test_m_rejects_nil
              assert_raises(ArgumentError) { B.new.m(nil) }
            end

            def test_k
              assert_equal 6, B.new.k(2)
            end

            def test_helper
              assert_equal 4, A.new.send(:helper, 2)
            end

            def test_helper_rejects_nil
              assert_raises(ArgumentError) { A.new.send(:helper, nil) }
            end

            def test_scale
              assert_equal 6, A.new.send(:scale, 2, 3)
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      rows = doc["tests"].to_h { |test| [test["name"].delete_prefix("BTest#"), [test["disposition"], test["tags"].first(2)]] }
      assert_equal({
        "test_m" => ["reported", ["caller:unchanged:lib/b.rb:5", "error:NoMethodError"]],
        "test_m_rejects_nil" => ["reported", ["assertion", "caller:unchanged:lib/b.rb:5"]],
        "test_k" => ["reported", ["caller:unchanged:lib/b.rb:9", "error:ArgumentError"]],
        "test_helper" => ["discarded", ["discard:signature_change", "error:NoMethodError"]],
        "test_helper_rejects_nil" => ["discarded", ["assertion", "discard:signature_change"]],
        "test_scale" => ["discarded", ["discard:signature_change", "error:ArgumentError"]]
      }, rows)
    end
  end

  def test_a_reader_removed_from_a_conditional_is_a_signature_change
    with_repo do |repo|
      repo.write("lib/order.rb", <<~RUBY)
        class Order
          attr_reader :total if true

          def initialize
            @total = 9
          end
        end
      RUBY
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/order.rb", <<~RUBY)
        class Order
          def initialize
            @total = 9
          end
        end
      RUBY
      repo.commit("Drop the readers.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "order_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "order"

          class OrderTest < Minitest::Test
            def test_total
              assert_equal 9, Order.new.total
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      assert_includes doc["methods"].map { |method| [method["name"], method["change"]] }, ["Order#total", "removed"]
      row = doc["tests"].fetch(0)
      assert_equal ["discarded", "discard:signature_change"], [row["disposition"], row["tags"].first]
    end
  end

  def test_a_removed_constructor_or_reader_is_a_signature_change_of_the_class_new_names
    with_repo do |repo|
      repo.write("lib/mismatch.rb", <<~RUBY)
        class Mismatch < StandardError
          attr_reader :reason, :seed

          def initialize(reason = nil, seed: nil)
            @reason, @seed = reason, seed
            super(reason)
          end
        end

        class Spec
          def initialize(path)
            @path = path
          end

          def path = @path
        end
      RUBY
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/mismatch.rb", <<~RUBY)
        class Mismatch < StandardError
          attr_reader :seed
        end

        class Spec
          def initialize(path)
            @path = path.to_s
          end

          def path = @path
        end
      RUBY
      repo.commit("Raise Mismatch with a message alone.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "mismatch_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "mismatch"

          class MismatchTest < Minitest::Test
            def test_takes_a_seed
              assert_equal "9", Mismatch.new("lost", seed: "9").seed
            end

            def test_reads_its_reason
              assert_equal "lost", Mismatch.new("lost").reason
            end

            def test_keeps_its_path
              assert_equal 3, Spec.new(3).path
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["name"].delete_prefix("MismatchTest#"), test] }
      seed = rows.fetch("test_takes_a_seed")
      assert_equal [ids["Mismatch#initialize"], []], [seed["method_id"], seed["method_ids"] - [ids["Mismatch#initialize"]]]
      assert_equal ["discarded", "discard:signature_change"], [seed["disposition"], seed["tags"].first]
      reason = rows.fetch("test_reads_its_reason")
      assert_equal ids.fetch("Mismatch#reason"), reason["method_id"]
      assert_equal ["discarded", "discard:signature_change"], [reason["disposition"], reason["tags"].first]
      path = rows.fetch("test_keeps_its_path")
      assert_equal [ids["Spec#initialize"], "reported"], path.values_at("method_id", "disposition")
      refute_includes path["tags"], "related:guess"
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
      assert_equal ["Geo::Point#scaled", "scaled"], by_name["GeoTest#test_point"]["mentions"]
      assert_includes by_name["GeoTest#test_point"]["tags"], "touches:changed_method"
      refute_includes by_name["GeoTest#test_point"]["tags"], "touches:changed_constant"
    end
  end

  def test_an_error_message_read_by_a_test_names_the_error_s_to_s
    with_repo do |repo|
      source = <<~RUBY
        class Mismatch < StandardError
          def initialize(var) = (@var = var; super())

          def to_s = "differs at \#{@var}"
        end

        module Check
          def self.run(var) = raise(Mismatch.new(var))

          def self.label(text) = "L\#{text}"
        end
      RUBY
      repo.write("lib/check.rb", source)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/check.rb", source.sub("differs at", "differs:").sub('"L', '"M'))
      repo.commit("Shorten the message.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "check_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "check"

          class CheckTest < Minitest::Test
            def test_message
              error = assert_raises(Mismatch) { Check.run("x") }
              assert_equal "differs at x", error.message
            end
          end
        RUBY
      })

      doc = execute(repo, tests)
      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      row = doc["tests"].fetch(0)

      assert_equal [ids.fetch("Mismatch#to_s"), [ids.fetch("Mismatch#to_s")]], row.values_at("method_id", "method_ids")
      assert_includes row["tags"], "touches:changed_method"
    end
  end

  def test_a_qualified_new_names_the_constructor_of_that_class_alone
    with_repo do |repo|
      source = "module A\n  class Box\n    attr_reader :n\n\n    def initialize(n) = (@n = n)\n  end\nend\n"
      repo.write("lib/box.rb", source + source.sub("module A", "module B"))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/box.rb", source.sub("@n = n", "@n = n * 2") + source.sub("module A", "module B").sub("@n = n", "@n = n + 1"))
      repo.commit("Scale the boxes.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "box_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "box"

          class BoxTest < Minitest::Test
            def test_qualified
              assert_equal 1, A::Box.new(1).n
            end

            def test_bare
              assert_equal 1, B::Box.new(1).n
            end
          end
        RUBY
      })

      doc = execute(repo, tests)
      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("method_id", "method_ids", "mentions")] }

      assert_equal [ids.fetch("A::Box#initialize"), [ids.fetch("A::Box#initialize")], ["A::Box#n", "A::Box.new", "n"]], rows.fetch("BoxTest#test_qualified")
      assert_equal [ids.fetch("B::Box#initialize"), [ids.fetch("B::Box#initialize")], ["B::Box#n", "B::Box.new", "n"]], rows.fetch("BoxTest#test_bare")
    end
  end

  def test_a_struct_given_more_values_than_its_members_is_a_signature_change
    with_repo do |repo|
      repo.write("lib/geo.rb", "module Geo\n  Point = Struct.new(:x, :y)\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/geo.rb", "module Geo\n  Point = Struct.new(:x)\nend\n")
      repo.commit("Drop y.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "geo_test.rb" => candidate_source("GeoTest", "test_y", "assert_equal 2, Geo::Point.new(1, 2).y").sub('require "calc"', 'require "geo"') })

      row = execute(repo, tests)["tests"].fetch(0)

      assert_equal ["discarded", "struct size differs"], [row["disposition"], row.dig("head", "message")]
      assert_includes row["tags"], "discard:signature_change"
    end
  end

  def test_a_guess_passes_over_an_edit_that_only_adds_a_call_to_an_added_method
    with_repo do |repo|
      source = <<~RUBY
        class Price
          def show(n) = "\#{total(n)}"

          def total(n)
            base(n) + 1
          end

          def base(n) = n * 2
        end
      RUBY
      repo.write("lib/price.rb", source)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/price.rb", source.sub("base(n) + 1\n", "base(n) + 1 - rebate(n)\n").sub("  def base(n) = n * 2\n", "  def base(n) = n * 2\n\n  def rebate(n) = n > 5 ? 3 : 0\n"))
      repo.commit("Take a rebate off a large total.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "price_test.rb" => candidate_source("PriceTest", "test_show", 'assert_equal "21", Price.new.show(10)').sub('require "calc"', 'require "price"') })

      doc = execute(repo, tests)
      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      row = doc["tests"].fetch(0)

      assert_equal [true], doc["methods"].select { |method| method["change"] == "modified" }.map { |method| method["forwards_to_added"] }
      assert_equal [ids.fetch("Price#rebate"), ids.values_at("Price#rebate", "Price#total").sort], row.values_at("method_id", "method_ids")
    end
  end

  def test_a_broken_call_on_a_changed_line_outside_a_method_is_a_changed_caller
    with_repo do |repo|
      repo.write("lib/rule.rb", "class Rule\n  def helper(x) = x\n\n  CHECK = ->(x) { new.helper(x) }\n\n  def run(x) = CHECK.call(x)\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/rule.rb", "class Rule\n  CHECK = ->(x) { new.helper(x) + 0 }\n\n  def run(x) = CHECK.call(x)\nend\n")
      repo.commit("Drop the helper.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "rule_test.rb" => candidate_source("RuleTest", "test_run", "assert_equal 1, Rule.new.run(1)").sub('require "calc"', 'require "rule"') })

      doc = execute(repo, tests)
      row = doc["tests"].fetch(0)

      assert_equal({ "lib/rule.rb" => [[2, 2]] }, doc["changed_lines"])
      assert_equal "reported", row["disposition"]
      assert_includes row["tags"], "caller:changed:lib/rule.rb:2"
    end
  end

  def test_an_error_row_names_the_error_it_was_raised_from
    with_repo do |repo|
      repo.write("lib/a.rb", "module A; def self.g = 1; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", %(module A; def self.g = (raise KeyError, "inner k" rescue raise ArgumentError, "outer"); end\n))
      repo.commit("Wrap a key error.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "a_test.rb" => candidate_source("ATest", "test_g", "assert_equal 1, A.g").sub('require "calc"', 'require "a"') })

      doc = execute(repo, tests)
      head = doc["tests"].fetch(0)["head"]

      assert_equal ["ArgumentError", "outer", { "error_class" => "KeyError", "message" => "inner k" }], head.values_at("error_class", "message", "cause")
      assert_equal({ "file" => "candidates/a_test.rb", "line" => 6 }, head["backtrace"].last)
      assert_includes JitCatch::Render.run_text(doc), "    outer\n    cause: KeyError: inner k\n    rerun: "
    end
  end

  def test_a_script_a_test_starts_lends_its_calls_to_the_mentions
    with_repo do |repo|
      tool = "module Tool\n  def self.run = value + 1\n\n  def self.value = 0\nend\n"
      repo.write("lib/tool.rb", tool)
      repo.write("exe/tool", "#!/usr/bin/env ruby\nrequire \"tool\"\nputs Tool.run\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/tool.rb", tool.sub("value = 0", "value = 1"))
      repo.commit("Start at one.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "tool_test.rb" => <<~RUBY
          require "minitest/autorun"

          class ToolTest < Minitest::Test
            def test_prints_one
              assert_equal "1\\n", IO.popen(["ruby", "-Ilib", "exe/tool"], &:read)
            end

            def test_prints_one_from_a_path_beside_the_file
              assert_equal "1\\n", IO.popen(["ruby", "-Ilib", File.expand_path("../exe/tool", __dir__)], &:read)
            end
          end
        RUBY
      })

      doc = execute(repo, tests)
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("method_id", "tags")] }

      assert_equal [["m01", %w[assertion report touches:unchanged_caller]]] * 2, rows.values_at("ToolTest#test_prints_one", "ToolTest#test_prints_one_from_a_path_beside_the_file")
      assert_equal "Tool.value", doc["methods"].find { |method| method["id"] == "m01" }&.fetch("name")
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

  # The run reads a copy of the tests directory at `.jitcatch/`, and the
  # rerun line names the directory by its path from the repository root,
  # so a message names that too, after `{worktree}/`.
  # A relative `.jitcatch/` (`__FILE__`) is left as it is: it cannot be
  # told apart from text a test compares.
  def test_a_message_names_the_tests_directory_where_it_named_the_copy
    with_repo do |repo|
      repo.write("lib/calc.rb", BASE_CALC)
      repo.commit("Initial calc", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", HEAD_CALC)
      repo.commit("Tweak calc helpers.", date: "2026-02-12T00:00:00Z")
      body = candidate_source("FixtureTest", "test_fixture", %(File.read(File.join(__dir__, "fixtures", "none.json")) unless __FILE__ == "x"))
      inside = File.join(repo.dir, "candidates")
      outside = Dir.mktmpdir("jitcatch-outside")
      write_tests(inside, { "fixture_test.rb" => body })
      write_tests(outside, { "fixture_test.rb" => body })

      messages = [inside, outside].map { |tests| execute(repo, tests)["tests"].fetch(0)["head"]["message"] }

      from_root = Pathname(File.realpath(outside)).relative_path_from(Pathname(File.realpath(repo.dir))).to_s
      assert_equal ["{worktree}/candidates/fixtures/none.json", "{worktree}/#{from_root}/fixtures/none.json"], messages.map { |message| message[/\S+none\.json/] }
    ensure
      FileUtils.rm_rf(outside) if outside
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

            def test_root
              assert_equal "x", "in \#{Dir.pwd}, the root, not \#{Dir.pwd}2"
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
      assert_includes by_name["WordsTest#test_root"]["head"]["message"], "in {worktree}, the root, not /", "a root with no path after it"
      assert_includes by_name["WordsTest#test_word"]["head"]["message"], "café"
      frames = doc["tests"].flat_map { |test| [test["base"], test["head"]] }.flat_map { |side| side["backtrace"] }.map { |frame| frame["file"] }
      assert_includes frames, "candidates/words_test.rb"
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
      repo.write("lib/calc.rb", "class Calc; end\n")
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
                #{block_until_killed(repo.dir)}
              end
              assert Flag.ok
            end
          end
        RUBY
      })
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      doc = execute(repo, tests, timeout: 1, reruns: 2, finished_in_time: blocked_children_time_out(repo.dir))
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 50, "the timed-out process was not killed"
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
      assert_includes JitCatch::Render.run_text(doc), "slow_test.rb#timeout slow_test.rb\n    hint: head timed out after 1s; raise --timeout if the file needs longer, as a Rails app's first run in a new checkout can (it loads db/schema.rb)\n"
    end
  end

  # A file that times out on base too says nothing about either side, as a
  # Rails app that loads its schema in each new checkout can.
  def test_discards_a_timeout_on_both_sides
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; def self.ok; true; end; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "slow_test.rb" => "require \"minitest/autorun\"\nrequire \"flag\"\n\nclass SlowTest < Minitest::Test\n  def test_slow\n    #{block_until_killed(repo.dir)}\n    assert Flag.ok\n  end\nend\n" })

      doc = execute(repo, tests, timeout: 1, reruns: 2, finished_in_time: blocked_children_time_out(repo.dir))

      assert_equal [0, 1, 0], doc["counts"].values_at("fail_on_base", "discarded", "reported")
      row = doc["tests"].fetch(0)
      assert_equal %w[slow_test.rb#timeout discarded timeout timeout], [row["name"], row["disposition"], row.dig("base", "status"), row.dig("head", "status")]
      assert_nil row["reruns"], "a timeout is not rerun"
      assert_includes row["tags"], "discard:timeout"
      assert_includes JitCatch::Render.run_text(doc), "    hint: base and head timed out after 1s; raise --timeout if the file needs longer, as a Rails app's first run in a new checkout can (it loads db/schema.rb)\n"
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
        "Calc#test_0001_doubles two" => ["reported", "ruby -Ilib -I. candidates/calc_spec.rb -n 'Calc#test_0001_doubles two'"],
        "Calc#test_0002_labels" => ["no_signal", "ruby -Ilib -I. candidates/calc_spec.rb -n Calc#test_0002_labels"]
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
        ["t01", "calc_test.rb", "CalcTest#test_double", ["Calc#double", "double"], "candidate", "reported"],
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
      assert_equal [%w[Price.new doubled], ids["Price#doubled"]], rows["PriceTest#test_doubled_through_a_helper"]
      assert_equal [%w[Price#cents Price.new cents], ids["Price#initialize"]], rows["PriceTest#test_new_keeps_the_cents"]
      assert_equal [%w[Box#size size], ids["Box#size"]], rows["PriceTest#test_box_new_is_not_price_new"]
      doc["tests"].each { |test| assert_includes test["tags"], "touches:changed_method", test["name"] }
    end
  end

  # A test that enters at the command line reaches a changed method five
  # calls down, past the callers `reachable_from` keeps, so the row's pool
  # holds that method next to the one the entry calls first.
  def test_a_test_that_enters_above_the_kept_callers_keeps_the_deep_method_in_its_pool
    with_repo do |repo|
      desk = <<~SOURCE
        class Desk
          def self.start(argv)
            new.route(argv)
          end

          def route(argv)
            argv.empty? ? help : serve(argv)
          end

          def help
            "usage: desk ITEM"
          end

          def serve(argv)
            price(argv.first)
          end

          def price(item)
            total(item)
          end

          def total(item)
            item.length + fee
          end

          def fee
            FEE
          end
        end
      SOURCE
      repo.write("lib/desk.rb", desk.sub("FEE", "1"))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/desk.rb", desk.sub("FEE", "2").sub("usage: desk ITEM", "usage: desk ITEM..."))
      repo.commit("Raise the fee and widen the usage line.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "desk_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "desk"

          class DeskTest < Minitest::Test
            def test_start_prices_an_item
              assert_equal 4, Desk.start(["tea"])
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      refute_includes doc["methods"].find { |method| method["name"] == "Desk#fee" }["reachable_from"], "Desk.start"
      row = doc["tests"].fetch(0)
      assert_equal [%w[Desk.start start], ids.values_at("Desk#fee", "Desk#help").sort], row.values_at("mentions", "method_ids")
      assert_includes row["tags"], "related:guess"
    end
  end

  def test_a_record_builder_and_a_factory_mention_the_constructor
    with_repo do |repo|
      record_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "record_standins.rb" => RECORD_STANDINS,
        "loan_test.rb" => <<~RUBY
          require "minitest/autorun"
          require_relative "record_standins"
          require "loan"

          class LoanTest < Minitest::Test
            include Factories

            def test_create_bang
              assert_equal "nobody", Loan.create!.approved_by
            end

            def test_factory
              assert_equal "nobody", create(:loan).approved_by
            end
          end
        RUBY
      })

      doc = execute(repo, tests)

      id = doc["methods"].find { |method| method["name"] == "Loan#initialize" }["id"]
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("mentions", "method_id")] }
      assert_equal({ "LoanTest#test_create_bang" => [%w[Loan.create! approved_by], id], "LoanTest#test_factory" => [%w[approved_by create(:loan)], id] }, rows)
      doc["tests"].each { |test| assert_includes test["tags"], "touches:changed_method", test["name"] }
    end
  end

  def test_a_save_mentions_the_callback_it_runs
    with_repo do |repo|
      callback_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "record_standins.rb" => RECORD_STANDINS,
        "loan_test.rb" => <<~TEST
          require "minitest/autorun"
          require_relative "record_standins"
          require "loan"

          class LoanTest < Minitest::Test
            include Factories

            def test_create_bang
              assert_equal 1, Loan.create!.saves
            end

            def test_factory
              assert_equal 1, create(:loan).saves
            end

            def test_save_bang
              loan = Loan.new
              loan.save!
              assert_equal 1, loan.saves
            end

            def test_build
              assert_nil build(:loan).saves
            end

            def test_build_save
              loan = build(:loan)
              loan.save!
              assert_equal 1, loan.saves
            end
          end
        TEST
      })

      doc = execute(repo, tests)

      # A save runs the validation's `if:` too, so the evidence cannot tell
      # the two apart; `before_destroy :archive` is not in the pool.
      ids = doc["methods"].select { |method| %w[Loan#checked? Loan#count_save].include?(method["name"]) }.map { |method| method["id"] }
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("mentions", "method_ids")] }
      assert_equal({
        "LoanTest#test_create_bang" => [%w[Loan.create! saves], ids],
        "LoanTest#test_factory" => [%w[create(:loan) saves], ids],
        "LoanTest#test_save_bang" => [%w[Loan#save! Loan#saves saves], ids],
        "LoanTest#test_build" => [%w[saves], []],
        "LoanTest#test_build_save" => [%w[build(:loan) saves], ids]
      }, rows)
      doc["tests"].each { |test| assert_includes test["tags"], "touches:changed_method", test["name"] unless test["name"] == "LoanTest#test_build" }
    end
  end

  def test_a_record_builder_written_inside_its_namespace_mentions_the_constructor
    with_repo do |repo|
      repo.write("lib/shop/loan.rb", "module Shop\n  class Loan < ActiveRecord::Base\n    attr_reader :mark\n\n    def initialize(attributes = nil)\n      @mark = 1\n    end\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/shop/loan.rb", "module Shop\n  class Loan < ActiveRecord::Base\n    attr_reader :mark\n\n    def initialize(attributes = nil)\n      @mark = 2\n    end\n  end\nend\n")
      repo.commit("Mark two.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "record_standins.rb" => RECORD_STANDINS,
        "loan_test.rb" => <<~RUBY
          require "minitest/autorun"
          require_relative "record_standins"
          require "shop/loan"

          module Shop
            class LoanTest < Minitest::Test
              def test_create_bang
                assert_equal 1, Loan.create!.mark
              end
            end
          end
        RUBY
      })

      row = execute(repo, tests)["tests"].fetch(0)

      assert_equal [%w[Loan.create! mark], "m01"], row.values_at("mentions", "method_id")
    end
  end

  # `File.write` shares its name with the caller `Emitter.write`, but File
  # is no constant of the repository, so the call reaches nothing here.
  def test_a_name_sent_only_to_a_constant_outside_the_repository_is_no_mention
    with_repo do |repo|
      emitter = ->(text) { "class Emitter\n  def self.write(path) = File.write(path, body)\n  def self.body = \"#{text}\"\nend\n" }
      repo.write("lib/emitter.rb", emitter.call("a"))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/emitter.rb", emitter.call("b"))
      repo.commit("Write b.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "emitter_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "emitter"
          require "tmpdir"

          class EmitterTest < Minitest::Test
            def test_file_write
              Dir.mktmpdir { |dir| File.write(File.join(dir, "x"), "a") && assert_equal("a", File.read(File.join(dir, "x"))) }
            end

            def test_emitter_write
              Dir.mktmpdir { |dir| Emitter.write(File.join(dir, "x")) && assert_equal("a", File.read(File.join(dir, "x"))) }
            end
          end
        RUBY
      })

      rows = execute(repo, tests)["tests"].to_h { |test| [test["name"], test.values_at("mentions", "method_id")] }

      assert_equal [[], nil], rows["EmitterTest#test_file_write"]
      assert_equal [%w[Emitter.write write], "m01"], rows["EmitterTest#test_emitter_write"]
    end
  end

  def test_the_receiver_class_picks_the_related_method_among_same_named_ones
    with_repo do |repo|
      same_named_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "parse_test.rb" => <<~TEST
          require "minitest/autorun"
          require "a"

          class ParseTest < Minitest::Test
            def test_index
              result = Index.parse("x")
              assert_equal "x", result
            end

            def test_log
              assert_equal "x", Log.parse("x")
            end
          end
        TEST
      })

      doc = execute(repo, tests)
      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("method_id", "method_ids")] }

      assert_equal [ids.fetch("Index.parse"), [ids.fetch("Index.parse")]], rows.fetch("ParseTest#test_index")
      assert_equal [ids.fetch("Log.parse"), [ids.fetch("Log.parse")]], rows.fetch("ParseTest#test_log")
    end
  end

  def test_a_call_through_a_picked_constant_is_related_and_one_through_a_lookup_says_so
    with_repo do |repo|
      leaf = "module Plain\n  def self.render(text) = text\nend\n\nmodule Fancy\n  def self.render(text) = BODY\nend\n"
      repo.write("lib/emit.rb", <<~RUBY)
        require "leaf"

        module Emit
          EMITTERS = { "plain" => Plain, "fancy" => Fancy }.freeze

          module_function

          def render(format, text) = emitter_for(format).render(text)

          def emitter_for(format) = format == "plain" ? Plain : Fancy

          def looked_up(format, text) = EMITTERS.fetch(format).render(text)
        end
      RUBY
      repo.write("lib/leaf.rb", leaf.sub("BODY", "text"))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/leaf.rb", leaf.sub("BODY", "text.upcase"))
      repo.commit("Shout the fancy text.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "emit_test.rb" => <<~TEST
          require "minitest/autorun"
          require "emit"

          class EmitTest < Minitest::Test
            def test_render
              assert_equal "x", Emit.render("fancy", "x")
            end

            def test_looked_up
              assert_equal "x", Emit.looked_up("fancy", "x")
            end
          end
        TEST
      })

      doc = execute(repo, tests)
      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("method_id", "dynamic_call", "tags")] }

      assert_equal ["m01", nil, %w[assertion report touches:unchanged_caller]], rows.fetch("EmitTest#test_render")
      assert_equal [nil, { "from" => "Emit.looked_up", "name" => "render" }, %w[assertion related:dynamic report]], rows.fetch("EmitTest#test_looked_up")
      assert_includes JitCatch::Render.run_text(doc), "    related: none, Emit.looked_up sends render to a receiver the source does not name\n"
      assert_includes JitCatch::Render.context_text(JitCatch::Changes.between(repo.dir, "base", "HEAD")), "    dynamic_callers: Emit.looked_up (render)\n"
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
      assert_equal [%w[Z.run_text run_text], ids["Z.run_text"]], rows["JobTest#test_text"]
      assert_equal [%w[B#run run], ids["B#run"]], rows["JobTest#test_symbol_and_constant"]
    end
  end

  def test_serial_runs_one_side_at_a_time_and_records_it
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "alone_test.rb" => <<~RUBY
          require "minitest/autorun"

          class AloneTest < Minitest::Test
            def test_no_other_side_runs
              mine = File.join(ENV.fetch("MEET_DIR"), Process.pid.to_s)
              File.write(mine, "")
              seen = 1
              deadline = Time.now + 0.5
              (seen = [seen, Dir.children(ENV.fetch("MEET_DIR")).size].max; sleep 0.01) while Time.now < deadline
              File.delete(mine)
              assert_equal 1, seen
            end
          end
        RUBY
      })

      Dir.mktmpdir("jitcatch-meet-") do |meet|
        ENV["MEET_DIR"] = meet
        raw = JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 0, timeout: 10, env: ["MEET_DIR"], serial: true)
        assert_equal [%w[pass pass]], raw["tests"].map { |test| [test.dig("base", "status"), test.dig("head", "status")] }
        assert raw["serial"]
        assert_includes JitCatch::Render.run_text(JitCatch::Assessor.apply(raw)), "\nserial\n"
        assert_raises(JitCatch::UsageError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, serial: true, workers: 2) }
      ensure
        ENV.delete("MEET_DIR")
      end
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

  # A Rails database.yml that names `app_test<%= ENV["TEST_ENV_NUMBER"] %>`
  # (the parallel_tests convention) then gives every process that runs at
  # the same time a database of its own.
  def test_each_checkout_gets_a_test_env_number_of_its_own
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      number = %(flunk "number=\#{ENV.fetch("TEST_ENV_NUMBER", "unset")}")
      write_tests(tests, {
        "a_number_test.rb" => candidate_source("ANumberTest", "test_number", number),
        "b_number_test.rb" => candidate_source("BNumberTest", "test_number", number)
      })

      doc = with_env("TEST_ENV_NUMBER" => "9") { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 0, workers: 2) }

      sides = doc["tests"].map { |test| [test["base"]["message_first_line"], test["head"]["message_first_line"]] }
      assert_equal [["number=1", "number=2"], ["number=3", "number=4"]], sides.sort
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
      assert_equal [%w[JITCATCH_PASS JITCATCH_UNSET], %w[JITCATCH_UNSET]], doc.values_at("env", "env_unset")
      assert_equal({ "base" => "none", "head" => "none" }, doc["bundle"])
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

      assert_equal({ "base" => "ok", "head" => "ok" }, doc["bundle"])
      row = doc["tests"].fetch(0)
      assert_equal ["reported", "pass", "fail"], [row["disposition"], row["base"]["status"], row["head"]["status"]], row["head"]["message"]
      assert_includes JitCatch::Render.run_text(doc), "timeout_s 10\nbundle base ok\nbundle head ok\ntests:\n"
    end
  end

  def test_stops_when_only_head_cannot_load_its_locked_gems
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "jitcatch_absent_gem", "9.9.9"\n))
      repo.commit("Add a Gemfile.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      # Run on, base passes and head cannot load, so the row read as a regression.
      failures = without_bundler_settings { setup_failures(repo, tests) }

      assert_equal({ "head" => [["Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems."], []] }, failures)
    end
  end

  def test_stops_when_only_base_cannot_load_its_locked_gems
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "jitcatch_absent_gem", "9.9.9"\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.git("rm", "-q", "Gemfile")
      repo.commit("Drop the Gemfile.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      failures = without_bundler_settings { setup_failures(repo, tests) }

      assert_equal({ "base" => [["Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems."], []] }, failures)
    end
  end

  def test_stops_when_a_side_with_no_gemfile_cannot_load_the_frameworks
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag\n  ON = true\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  ON = false\nend\n")
      repo.commit("Turn the flag off.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "flag_spec.rb" => %(require "flag"\nRSpec.describe(Flag) { it("is on") { expect(Flag::ON).to be(true) } }\n),
        "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert Flag::ON").sub('require "calc"', 'require "flag"')
      })
      gems = File.join(repo.dir, "no-gems")
      FileUtils.mkdir_p(gems)

      err = with_env("GEM_HOME" => gems, "GEM_PATH" => gems) {
        assert_raises(JitCatch::EnvironmentError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 0) }
      }

      stderr = ["rspec-core is not installed for this Ruby: gem install rspec-core", "minitest is not installed for this Ruby: gem install minitest"]
      expected = ->(side, ref) { { "side" => side, "commit" => repo.git("rev-parse", ref).strip, "command" => %(ruby -e 'require "rspec/core"; require "minitest"'), "stderr" => stderr, "not_passed" => [] } }
      assert_equal [expected.("base", "base"), expected.("head", "HEAD")], err.doc["setup_failed"]
    end
  end

  # A Rails app that cannot reach its database fails in rails_helper, so
  # every file is a `#load` row on both sides and reads as `fail_on_base`.
  def test_stops_when_every_file_fails_to_load_on_both_sides
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      boot = %(raise IOError, "connection to server at 127.0.0.1 port 1 failed\\nIs the server running?" unless File.exist?("lib/booted.rb")\n)
      write_tests(tests, {
        "support.rb" => boot,
        "a_test.rb" => candidate_source("ATest", "test_a", "assert true").sub(%(require "calc"\n), %(require "calc"\nrequire_relative "support"\n)),
        "b_test.rb" => candidate_source("BTest", "test_b", "assert true").sub(%(require "calc"\n), %(require "calc"\nrequire_relative "support"\n))
      })

      err = assert_raises(JitCatch::EnvironmentError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 0) }

      assert_equal "load", err.doc["stage"]
      assert_equal [%w[base base], %w[head HEAD]].map { |side, ref| [side, repo.git("rev-parse", ref).strip] }, err.doc["setup_failed"].map { |failure| failure.values_at("side", "commit") }
      assert_equal ["ruby -Ilib -I. candidates/a_test.rb"] * 2, err.doc["setup_failed"].map { |failure| failure["command"] }
      # Ruby 3.3 quotes the frame label with a backtick, Ruby 3.4 and later with '.
      quote = RUBY_VERSION < "3.4" ? "`" : "'"
      assert_equal [["{worktree}/candidates/support.rb:1:in #{quote}<top (required)>': connection to server at 127.0.0.1 port 1 failed (IOError)"]] * 2, err.doc["setup_failed"].map { |failure| failure["stderr"] }
      assert_includes JitCatch::Render.setup_failed_text(err.doc), "jitcatch: every candidate file failed to load on both sides, so no row can tell base from head\n"
      assert_includes JitCatch::Render.setup_failed_text(err.doc), "is not in the checkouts jitcatch makes; pass its value with --env, such as RAILS_MASTER_KEY.\n"

      repo.write("lib/booted.rb", "\n")
      repo.commit("Boot.", date: "2026-02-13T00:00:00Z")
      doc = JitCatch::Runner.run(repo.dir, "HEAD~1", "HEAD", tests, reruns: 0)
      assert_equal %w[fail_on_base fail_on_base], doc["tests"].map { |test| test["classification"] }
    end
  end

  def test_a_directory_with_no_candidate_runs_to_an_empty_report
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.write("README.md", "head\n")
      repo.commit("Touch readme.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      FileUtils.mkdir_p(tests)

      doc = JitCatch::Runner.run(repo.dir, "HEAD~1", "HEAD", tests, reruns: 0)

      assert_equal [], doc["tests"]
    end
  end

  def test_a_failed_bundle_names_the_bundler_settings_it_did_not_get
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("Gemfile", %(source "https://rubygems.org"\ngroup :db do\n  gem "jitcatch_absent_gem", "9.9.9"\nend\n))
      repo.write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    jitcatch_absent_gem (9.9.9)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  jitcatch_absent_gem (= 9.9.9)\n")
      repo.commit("Add a Gemfile.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      failed, passed = without_bundler_settings do
        with_env("BUNDLE_WITHOUT" => "db", "BUNDLE_SILENCE_ROOT_WARNING" => "1") do
          [setup_failures(repo, tests, env: %w[BUNDLE_SILENCE_ROOT_WARNING]), setup_failures(repo, tests, env: %w[BUNDLE_WITHOUT])].map { |failures| failures.fetch("head") }
        end
      end

      assert_equal [["Could not find jitcatch_absent_gem-9.9.9 in locally installed gems"], %w[BUNDLE_WITHOUT]], failed
      # Passed, the setting skips the absent gem, and the next check speaks.
      assert_equal [['minitest is not in the bundle: add gem "minitest" to the Gemfile'], %w[BUNDLE_SILENCE_ROOT_WARNING]], passed
    end
  end

  def test_each_side_reads_the_bundler_settings_of_the_checkout
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "jitcatch_vendored", "1.0"\ngroup :db do\n  gem "jitcatch_absent_gem", "9.9.9"\nend\n))
      repo.write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    jitcatch_absent_gem (9.9.9)\n    jitcatch_vendored (1.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  jitcatch_absent_gem (= 9.9.9)\n  jitcatch_vendored (= 1.0)\n")
      repo.write(".gitignore", ".bundle/\nvendor/\n")
      repo.commit("Add a Gemfile.", date: "2026-02-12T00:00:00Z")
      gems = "vendor/bundle/ruby/#{RbConfig::CONFIG["ruby_version"]}"
      repo.write("#{gems}/specifications/jitcatch_vendored-1.0.gemspec", %(Gem::Specification.new { |s| s.name = "jitcatch_vendored"; s.version = "1.0"; s.summary = "x"; s.authors = ["x"] }\n))
      repo.write("#{gems}/gems/jitcatch_vendored-1.0/lib/jitcatch_vendored.rb", "")
      repo.write(".bundle/config", %(---\nBUNDLE_PATH: "vendor/bundle"\nBUNDLE_WITHOUT: "db"\n))
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      failures = without_bundler_settings { setup_failures(repo, tests) }

      # The vendored gem loads and the db group is skipped, so the next check speaks.
      assert_equal [['minitest is not in the bundle: add gem "minitest" to the Gemfile'], []], failures.fetch("head")
    end
  end

  def test_stops_on_a_bundle_that_does_not_list_minitest
    with_repo do |repo|
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.write("Gemfile", %(source "https://rubygems.org"\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\nend\n")
      repo.commit("Reformat.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_test.rb" => candidate_source("FlagTest", "test_flag", "assert true").sub('require "calc"', 'require "flag"') })

      failures = without_bundler_settings { setup_failures(repo, tests) }

      missing = [['minitest is not in the bundle: add gem "minitest" to the Gemfile'], []]
      assert_equal({ "base" => missing, "head" => missing }, failures)
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

  def execute(repo, tests, reruns: 0, timeout: 10, env: [], finished_in_time: nil)
    raw = JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: reruns, timeout: timeout, env: env, finished_in_time: finished_in_time)
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
