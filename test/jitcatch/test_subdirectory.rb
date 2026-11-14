# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "shellwords"

# A gem that lives in a directory of a larger repository, as `ruby/` of a
# monorepo, with its own lib/, Gemfile, and Gemfile.lock. jitcatch run from
# that directory runs every candidate there, and prints rerun lines that
# run from there.
class TestSubdirectory < Minitest::Test
  BIN = File.expand_path("../../bin/jitcatch", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  CALC = <<~RUBY
    class Calc
      def double(n)
        n * 2
      end
    end
  RUBY

  def test_a_run_from_the_gem_directory_uses_its_lib_and_gemfile
    with_monorepo do |repo, gem_dir|
      tests = File.join(gem_dir, "catch")
      write_tests(tests, {
        "double_test.rb" => <<~RUBY,
          require "minitest/autorun"
          require "calc"

          class DoubleTest < Minitest::Test
            def test_double
              assert_equal 4, Calc.new.double(2)
            end
          end
        RUBY
        "place_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "dep"

          class PlaceTest < Minitest::Test
            def test_runs_in_the_gem_directory_with_its_bundle
              assert_equal ["ruby", File.expand_path("Gemfile"), "1.0.0"],
                [File.basename(Dir.pwd), ENV["BUNDLE_GEMFILE"], Gem.loaded_specs.fetch("dep").version.to_s]
            end
          end
        RUBY
      })

      doc, status = jitcatch_json(gem_dir, "run", "base", "HEAD", "catch")

      assert_equal 0, status.exitstatus
      assert_equal "ruby", doc["directory"]
      assert_equal "catch", doc["tests_dir"]
      assert_equal({ "base" => "ok", "head" => "ok" }, doc["bundle"])
      place = doc["tests"].find { |row| row["file"] == "place_test.rb" }
      assert_equal %w[pass pass], [place["base"]["status"], place["head"]["status"]], place["head"]["message"]

      row = doc["tests"].find { |test| test["file"] == "double_test.rb" }
      assert_equal ["reported", "pass", "fail"], [row["disposition"], row["base"]["status"], row["head"]["status"]], row["head"]["message"]
      assert_equal "ruby/lib/calc.rb", doc["methods"].fetch(0)["file"]
      assert_equal doc["methods"].fetch(0)["id"], row["method_id"]
      assert_equal "bundle exec ruby -Ilib -I. catch/double_test.rb -n DoubleTest#test_double", row["rerun"]

      output, rerun = Open3.capture2e(*Shellwords.split(row["rerun"]), chdir: gem_dir)
      refute rerun.success?, output
      assert_includes output, "Expected: 4"

      text, = Open3.capture2e(RbConfig.ruby, "-I#{LIB}", BIN, "run", "base", "HEAD", "catch", chdir: gem_dir)
      assert_includes text, "\ndirectory ruby (candidates, the bundle check, and each rerun line run here; file paths are from the repository root)\n"
      refute_includes text, repo.dir
    end
  end

  # `--repo DIR` names the directory a run works from, as the working
  # directory does, so naming the gem's directory from the top is the same
  # run as one started inside it.
  def test_repo_naming_the_gem_directory_is_the_same_run
    with_monorepo do |repo, gem_dir|
      write_tests(File.join(gem_dir, "catch"), {
        "double_test.rb" => <<~RUBY
          require "minitest/autorun"
          require "calc"

          class DoubleTest < Minitest::Test
            def test_double
              assert_equal 4, Calc.new.double(2)
            end
          end
        RUBY
      })

      inside, = jitcatch_json(gem_dir, "run", "base", "HEAD", "catch")
      from_top, = jitcatch_json(repo.dir, "run", "--repo", "ruby", "base", "HEAD", "ruby/catch")

      assert_equal inside, from_top
    end
  end

  # The change is the repository's whatever directory reads it, and the
  # locked gems are those of the lockfile beside that directory's Gemfile.
  def test_context_from_the_gem_directory_reads_its_lockfile
    with_repo do |repo|
      repo.write("ruby/lib/calc.rb", CALC)
      repo.write("ruby/Gemfile.lock", lockfile("1.0.0"))
      repo.commit("Add the gem.", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("ruby/lib/calc.rb", CALC.sub("n * 2", "n * 2 + 1"))
      repo.write("ruby/Gemfile.lock", lockfile("1.1.0"))
      repo.commit("Tweak double and bump dep.", date: "2026-02-12T00:00:00Z")
      gem_dir = File.join(repo.dir, "ruby")

      inside, = jitcatch_json(gem_dir, "context", "base", "HEAD")
      from_top, = jitcatch_json(repo.dir, "context", "base", "HEAD")

      assert_equal %w[ruby/lib/calc.rb], inside["methods"].map { |method| method["file"] }
      assert_equal from_top["methods"], inside["methods"]
      assert_equal [{ "gem" => "dep", "old" => "1.0.0", "new" => "1.1.0" }], inside["dependencies"]
      assert_equal [], from_top["dependencies"]
    end
  end

  private

  # The top holds a lib/calc.rb of its own that raises when loaded, so a
  # candidate that loads it says which lib/ was on the load path.
  def with_monorepo
    with_repo do |repo|
      repo.write("lib/calc.rb", %(raise "the top's lib/ is on the load path"\n))
      repo.write("ruby/lib/calc.rb", CALC)
      repo.write("ruby/Gemfile", %(source "https://rubygems.org"\ngem "minitest"\ngem "dep", path: "vendor/dep"\n))
      repo.write("ruby/vendor/dep/dep.gemspec", dep_gemspec)
      repo.write("ruby/vendor/dep/lib/dep.rb", %(module Dep; end\n))
      repo.commit("Add the gem.", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("ruby/lib/calc.rb", CALC.sub("n * 2", "n * 2 + 1"))
      repo.commit("Tweak double.", date: "2026-02-12T00:00:00Z")
      yield repo, File.join(repo.dir, "ruby")
    end
  end

  def jitcatch_json(dir, command, *args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", BIN, command, "--json", *args, chdir: dir)
    assert_includes [0, 3], status.exitstatus, stderr
    [JSON.parse(stdout), status]
  end

  # `context` reads a lockfile as text for its locked versions.
  def lockfile(version)
    "GEM\n  remote: https://rubygems.org/\n  specs:\n    dep (#{version})\n"
  end

  def dep_gemspec
    <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "dep"
        spec.version = "1.0.0"
        spec.summary = "dep"
        spec.authors = ["jittest"]
        spec.files = ["lib/dep.rb"]
      end
    RUBY
  end
end
