# frozen_string_literal: true

require_relative "../test_helper"

# These run the real rspec-core. It is not a dependency of jitcatch, so on a
# Ruby without it installed they skip.
class TestRSpecRunner < Minitest::Test
  BASE_CART = <<~RUBY
    class Cart
      def initialize(prices)
        @prices = prices
      end

      def total
        @prices.sum
      end

      def label
        "cart"
      end

      def discount(rate)
        total * rate
      end

      def count
        @prices.size
      end
    end
  RUBY

  HEAD_CART = <<~RUBY
    class Cart
      def initialize(prices)
        @prices = prices
      end

      def total
        @prices.sum + 1
      end

      def label
        "cart"
      end

      def discount(rate, cap)
        [total * rate, cap].min
      end
    end
  RUBY

  SPEC_HELPER = <<~RUBY
    require "cart"

    RSpec.configure do |config|
      config.order = :random
    end
  RUBY

  RAILS_HELPER = <<~RUBY
    require "spec_helper"
    require File.expand_path("../config/environment", __dir__)
  RUBY

  # CI sets JITCATCH_RSPEC=required, so a bundle that lost rspec-core fails
  # the job instead of skipping these.
  def setup
    return unless Gem::Specification.find_all_by_name("rspec-core").empty?

    flunk "rspec-core is not installed for #{RUBY_VERSION}" if ENV["JITCATCH_RSPEC"] == "required"
    skip "rspec-core is not installed for #{RUBY_VERSION}"
  end

  def rails_shaped(repo, cart)
    repo.write("lib/cart.rb", cart)
    repo.write("config/environment.rb", "APP_ENV = \"test\"\n")
    repo.write(".rspec", "--require spec_helper\n--format documentation\n")
    repo.write("spec/spec_helper.rb", SPEC_HELPER)
    repo.write("spec/rails_helper.rb", RAILS_HELPER)
  end

  def cart_history(repo)
    rails_shaped(repo, BASE_CART)
    repo.commit("base", date: "2026-02-11T00:00:00Z")
    repo.branch("base")
    rails_shaped(repo, HEAD_CART)
    repo.commit("Add one to the total, cap the discount, drop count.", date: "2026-02-12T00:00:00Z")
  end

  def test_classifies_each_example_of_a_spec_that_requires_rails_helper
    with_repo do |repo|
      cart_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "cart_spec.rb" => <<~RUBY,
          require "rails_helper"

          RSpec.describe Cart do
            subject(:cart) { described_class.new(prices) }

            let(:prices) { [1, 2] }

            describe "#total" do
              before { prices << 3 }

              it "sums the prices" do
                expect(cart.total).to eq(6)
              end
            end

            describe "#label" do
              it "names the cart" do
                expect(cart.label).to eq("cart")
              end
            end

            it "counts the prices" do
              expect(cart.count).to eq(2)
            end

            it "takes one rate" do
              expect { cart.discount(1) }.not_to raise_error
            end

            it "knows the app" do
              expect(APP_ENV).to eq("prod")
            end
          end
        RUBY
        "broken_spec.rb" => <<~RUBY
          require "rails_helper"
          require "cart_missing" if Cart.instance_method(:discount).arity == 2

          RSpec.describe Cart do
            it("builds") { expect(Cart.new([]).label).to eq("cart") }
          end
        RUBY
      })

      doc = execute(repo, tests)

      rows = doc["tests"].to_h { |test| [test["name"], test.values_at("disposition", "line", "tags", "mentions")] }
      assert_equal({
        "broken_spec.rb#load" => ["discarded", nil, ["discard:load_error", "error:LoadError", "touches:changed_method"], %w[Cart#label Cart.new discount label]],
        "Cart#label names the cart" => ["no_signal", 17, [], %w[Cart#label Cart.new label]],
        "Cart#total sums the prices" => ["reported", 11, %w[assertion report touches:changed_method], %w[Cart#total Cart.new total]],
        "Cart counts the prices" => ["discarded", 22, ["discard:signature_change", "error:NoMethodError", "touches:changed_method"], %w[Cart#count Cart.new count]],
        "Cart knows the app" => ["fail_on_base", 30, [], %w[Cart.new]],
        "Cart takes one rate" => ["discarded", 26, ["assertion", "discard:signature_change", "touches:changed_method"], %w[Cart#discount Cart.new discount]]
      }, rows, doc["tests"].map { |test| [test["name"], test["head"]["message"]] }.inspect)

      total = doc["tests"].find { |test| test["name"] == "Cart#total sums the prices" }
      assert_equal "expected: 6", total["head"]["message_first_line"]
      assert_equal JitCatch::Framework::RSpec.rerun("cart_spec.rb", nil, 11), total["rerun"]
      assert_equal JitCatch::Framework::RSpec.rerun("broken_spec.rb", nil, nil), doc["tests"].find { |test| test["name"] == "broken_spec.rb#load" }["rerun"]

      text = JitCatch::Render.run_text(doc)
      assert_includes text, "reported Cart#total sums the prices cart_spec.rb:11 #{total["method_id"]}\n"
      assert_includes text, "    expected: 6\n    got: 7\n    rerun: #{total["rerun"]}\n"
    end
  end

  def test_a_removed_method_that_unchanged_code_still_calls_is_reported
    with_repo do |repo|
      inherited_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "b_spec.rb" => <<~RUBY
          require "b"

          RSpec.describe B do
            it("m doubles") { expect(B.new.m(2)).to eq(4) }
            it("m rejects nil") { expect { B.new.m(nil) }.to raise_error(ArgumentError) }
            it("k triples") { expect(B.new.k(2)).to eq(6) }
            it("helper doubles") { expect(A.new.send(:helper, 2)).to eq(4) }
            it("helper rejects nil") { expect { A.new.send(:helper, nil) }.to raise_error(ArgumentError) }
            it("scale multiplies") { expect(A.new.send(:scale, 2, 3)).to eq(6) }
          end
        RUBY
      })

      doc = execute(repo, tests)

      rows = doc["tests"].to_h { |test| [test["name"].delete_prefix("B "), [test["disposition"], test["tags"].first(2)]] }
      assert_equal({
        "m doubles" => ["reported", ["caller:unchanged:lib/b.rb:5", "error:NoMethodError"]],
        "m rejects nil" => ["reported", ["assertion", "caller:unchanged:lib/b.rb:5"]],
        "k triples" => ["reported", ["caller:unchanged:lib/b.rb:9", "error:ArgumentError"]],
        "helper doubles" => ["discarded", ["discard:signature_change", "error:NoMethodError"]],
        "helper rejects nil" => ["discarded", ["assertion", "discard:signature_change"]],
        "scale multiplies" => ["discarded", ["discard:signature_change", "error:ArgumentError"]]
      }, rows)
    end
  end

  # RSpec puts lib/ of the nearest directory that holds spec/ first on the
  # load path, so a repository under a Rails app's tmp/ would load the app's
  # lib/ in the run's worktrees and in the rerun line.
  def test_the_run_and_its_rerun_load_the_repository_s_lib_under_another_project
    Dir.mktmpdir("jitcatch-outer-") do |outer|
      FileUtils.mkdir_p(File.join(outer, "spec"))
      FileUtils.mkdir_p(File.join(outer, "lib"))
      File.write(File.join(outer, "lib", "price.rb"), "module Price\n  def self.cents = 100\nend\n")
      repo = Support::Repo.new(File.join(outer, "tmp", "repo"))
      repo.write("lib/price.rb", "module Price\n  def self.cents = 100\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/price.rb", "module Price\n  def self.cents = 101\nend\n")
      repo.commit("Add a cent.", date: "2026-02-12T00:00:00Z")
      tests = File.join(outer, "candidates")
      write_tests(tests, {
        "price_spec.rb" => %(require "price"\n\nRSpec.describe(Price) { it("costs a dollar") { expect(Price.cents).to eq(100) } }\n)
      })

      doc = with_env("TMPDIR" => File.join(outer, "tmp")) { execute(repo, tests) }

      row = doc["tests"].fetch(0)
      assert_equal "reported", row["disposition"], row["head"]["message"]
      words = Shellwords.split(row["rerun"]).map { |word| word.sub(JitCatch::Framework::TESTS, "#{tests}/") }
      stdout, status = Open3.capture2e(*words, chdir: repo.dir)
      refute status.success?, stdout
      assert_includes stdout, "got: 101"
    end
  end

  def test_a_flaky_example_is_dropped_and_its_neighbors_are_not_rerun_as_flaky
    with_repo do |repo|
      cart_history(repo)
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "flip_spec.rb" => <<~RUBY
          require "spec_helper"

          RSpec.describe Cart do
            it "is stable" do
              expect(Cart.new([1]).total).to eq(1)
            end

            it "flips" do
              runs = File.exist?("count") ? File.read("count").to_i : 0
              File.write("count", (runs + 1).to_s)
              expect(Cart.new([1]).total + runs).to eq(1)
            end
          end
        RUBY
      })

      doc = execute(repo, tests, reruns: 2)

      assert_equal({ "Cart flips" => "flaky", "Cart is stable" => "reported" }, doc["tests"].to_h { |test| [test["name"], test["disposition"]] })
    end
  end

  def test_a_bundle_with_rspec_and_no_minitest_runs_spec_candidates
    with_repo do |repo|
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "rspec-core"\ngem "rspec-expectations"\n))
      repo.write("lib/flag.rb", "module Flag\n  ON = true\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\n  ON = false\nend\n")
      repo.commit("Turn the flag off.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, {
        "flag_spec.rb" => %(require "flag"\n\nRSpec.describe Flag do\n  it("is on") { expect(Flag::ON).to be(true) }\nend\n)
      })

      doc = execute(repo, tests)

      assert_equal({ "base" => { "status" => "ok", "message" => "" }, "head" => { "status" => "ok", "message" => "" } }, doc["bundle"])
      row = doc["tests"].fetch(0)
      assert_equal ["Flag is on", "reported", "bundle exec #{JitCatch::Framework::RSpec.rerun("flag_spec.rb", nil, 4)}"], row.values_at("name", "disposition", "rerun"), row["head"]["message"]
    end
  end

  def test_a_bundle_without_rspec_says_so
    with_repo do |repo|
      repo.write("Gemfile", %(source "https://rubygems.org"\ngem "minitest"\n))
      repo.write("lib/flag.rb", "module Flag; end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/flag.rb", "module Flag\nend\n")
      repo.commit("Reformat.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "flag_spec.rb" => %(require "flag"\nRSpec.describe(Flag) { it("loads") { expect(Flag).to be_a(Module) } }\n) })

      doc = without_bundler_settings { execute(repo, tests) }

      missing = { "status" => "failed", "message" => 'rspec-core is not in the bundle: add gem "rspec" to the Gemfile' }
      assert_equal({ "base" => missing, "head" => missing }, doc["bundle"])
    end
  end

  def test_a_raise_error_row_keeps_the_whole_message_that_came
    with_repo do |repo|
      repo.write("lib/a.rb", %(module A; def self.f = raise(KeyError, "k"); end\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", %(module A; def self.f = raise(ArgumentError, "#{"x" * 200} wrapped k"); end\n))
      repo.commit("Wrap the key error.", date: "2026-02-12T00:00:00Z")
      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "a_spec.rb" => %(require "a"\n\nRSpec.describe A do\n  it("raises a key error") { expect { A.f }.to raise_error(KeyError) }\nend\n) })

      row = execute(repo, tests)["tests"].fetch(0)

      assert_equal "expected KeyError, got #<ArgumentError: #{"x" * 200} wrapped k>", row["head"]["message"]
      rerun = Shellwords.split(row["rerun"]).map { |part| part.sub("{tests}/", "#{tests}/") }
      out, _status = Open3.capture2e(*rerun, chdir: repo.dir)
      assert_includes out, "#{"x" * 200} wrapped k>"
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
      write_tests(tests, { "a_spec.rb" => %(require "a"\n\nRSpec.describe A do\n  it("gets one") { expect(A.g).to eq(1) }\nend\n) })

      doc = execute(repo, tests)

      # Ruby 3.3 adds a `rescue in` frame on the same line as the error's own.
      assert_equal({ "file" => ".jitcatch/a_spec.rb", "line" => 4 }, doc["tests"].fetch(0)["head"]["backtrace"].last)
      assert_includes JitCatch::Render.run_text(doc), "    outer\n    cause: KeyError: inner k\n    rerun: "
    end
  end

# The example's group or its receiver names the class whose `parse` it calls.
def test_the_described_class_picks_the_related_method_among_same_named_ones
  with_repo do |repo|
    same_named_history(repo)
    tests = File.join(repo.dir, "candidates")
    write_tests(tests, {
      "index_spec.rb" => %(require "a"\n\nRSpec.describe Index do\n  let(:result) { described_class.parse("x") }\n\n  it("keeps the text") { expect(result).to eq("x") }\nend\n),
      "log_spec.rb" => %(require "a"\n\nRSpec.describe "a log" do\n  it("keeps the text") { expect(Log.parse("x")).to eq("x") }\nend\n)
    })

      doc = execute(repo, tests)
      ids = doc["methods"].to_h { |method| [method["name"], method["id"]] }
      rows = doc["tests"].to_h { |test| [test["file"], test.values_at("method_id", "method_ids")] }

      assert_equal [ids.fetch("Index.parse"), [ids.fetch("Index.parse")]], rows.fetch("index_spec.rb")
      assert_equal [ids.fetch("Log.parse"), [ids.fetch("Log.parse")]], rows.fetch("log_spec.rb")
    end
  end

  def execute(repo, tests, reruns: 0)
    raw = JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: reruns, timeout: 20)
    JitCatch::Assessor.apply(raw)
  end
end
