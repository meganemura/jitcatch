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

      json = JitCatch::Render.dump(JitCatch::Render.run_json(doc))
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
              path = #{marker.inspect}
              n = File.exist?(path) ? Integer(File.read(path)) : 0
              File.write(path, (n + 1).to_s)
              flunk "flip" if n == 1
            end
          end
        RUBY
      })
      doc = execute(repo, tests, reruns: 2)
      assert_equal 1, doc["counts"]["generated"]
      assert_equal 1, doc["counts"]["flaky"]
      assert_equal 0, doc["counts"]["candidates"]
      assert_equal "flaky", doc["tests"].fetch(0)["disposition"]
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
      write_tests(tests, {
        "slow_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "flag"

          class SlowTest < Minitest::Test
            def test_slow
              sleep 5 if Dir.pwd.end_with?("/head")
              assert Flag.ok
            end
          end
        RUBY
      })
      doc = execute(repo, tests, timeout: 1, reruns: 0)
      assert_equal 1, doc["counts"]["generated"]
      assert_equal 1, doc["counts"]["discarded"]
      assert_equal 0, doc["counts"]["reported"]
      row = doc["tests"].fetch(0)
      assert_equal "discarded", row["disposition"]
      assert_includes row["tags"], "discard:timeout"
      assert_equal "pass", row["base"]["status"]
      assert_equal "timeout", row["head"]["status"]
      assert_equal "slow_test.rb#timeout", row["name"]
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
        ["t03", "test_extra.rb", "test_extra.rb#load", [], "candidate", "discarded"]
      ], rows
      assert_equal ["pass", "LoadError"], doc["tests"][2].values_at("base", "head").map { |side| side["error_class"] || side["status"] }
      assert_raises(JitCatch::UsageError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", File.join(repo.dir, "nope")) }
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
          end
        RUBY
      })
      parent = { "RUBYOPT" => "-W:no-deprecated", "CI" => "1", "HEGEL_SEED" => "7", "JITCATCH_PARENT_ONLY" => "x",
                 "GEM_HOME" => gems[0], "GEM_PATH" => gems[1] }
      saved = ENV.to_h.slice(*parent.keys)
      begin
        ENV.update(parent)
        doc = execute(repo, tests)
      ensure
        parent.each_key { |key| ENV.delete(key) }
        ENV.update(saved)
      end
      assert_equal %w[pass pass], doc["tests"].map { |test| test["base"]["status"] }, doc["tests"].map { |test| test["base"]["message"] }.join("\n")
    end
  end

  def execute(repo, tests, reruns: 0, timeout: 10)
    raw = JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: reruns, timeout: timeout)
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
