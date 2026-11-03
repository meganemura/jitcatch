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
