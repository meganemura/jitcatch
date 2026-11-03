# frozen_string_literal: true

require_relative "../test_helper"

class TestChangesGraph < Minitest::Test
  CHAIN = <<~RUBY
    class Chain
      def a1
        a2
      end

      def a2
        a3
      end

      def a3
        a4
      end

      def a4
        a5
      end

      def a5
        a6
      end

      def a6
        BODY
      end

      def gone
        1
      end

      def user
        gone
      end
    end
  RUBY

  KIND = <<~RUBY
    class Kind
      def self.go
        1
      end

      def go
        2
      end

      def run
        go
      end
    end
  RUBY

  def test_call_graph_depth_callsite_cap_kinds_and_removed_callers
    with_repo do |repo|
      callers = (1..9).map { |n| "  def c#{n}\n    Hub.new.target\n  end\n" }.join("\n")
      repo.write("lib/chain.rb", CHAIN.sub("BODY", "6"))
      repo.write("lib/kind.rb", KIND)
      repo.write("lib/hub.rb", "class Hub\n  def target\n    1\n  end\nend\n\nclass Callers\n#{callers}end\n")
      repo.write("test/chain_test.rb", "Chain.new.a6\nHub.new.target\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/chain.rb", CHAIN.sub("BODY", "7").sub("  def gone\n    1\n  end\n\n", "").sub("    gone\n", "    0\n"))
      repo.write("lib/kind.rb", KIND.sub("    1\n", "    10\n").sub("    2\n", "    20\n"))
      repo.write("lib/hub.rb", "class Hub\n  def target\n    2\n  end\nend\n\nclass Callers\n#{callers}end\n")
      repo.commit("Change the leaves.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      by_name = doc["methods"].to_h { |method| [method["name"], method] }

      assert_equal %w[Chain#a2 Chain#a3 Chain#a4 Chain#a5], by_name.fetch("Chain#a6")["reachable_from"]
      assert_equal ["lib/chain.rb"], by_name.fetch("Chain#a6")["callsites"].map { |site| site["file"] }
      assert_equal ["removed", ["Chain#user"]], [by_name.fetch("Chain#gone")["change"], by_name["Chain#gone"]["callsites"].map { |site| site["enclosing"] }]
      assert_equal [["Kind#run"], []], [by_name.fetch("Kind#go")["callsites"].map { |site| site["enclosing"] }, by_name.fetch("Kind.go")["callsites"]]
      target = by_name.fetch("Hub#target")
      assert_equal [8, 1], [target["callsites"].size, target["callsites_omitted"]]
      assert_includes JitCatch::Render.context_text(doc), "(+1 more)"
    end
  end

  RECEIVERS = <<~RUBY
    module Ns
      class A
        def strip
          BODY
        end

        def self.build
          BODY
        end

        def again
          strip
        end

        def mine
          self.strip
        end

        def remake
          self.class.build
        end

        def on_a_result
          again.strip
        end

        def on_a_self_result
          self.again.build
        end

        def self.sample
          new.strip
        end
      end

      class B
        def text(line)
          line.strip
        end

        def fresh
          A.new.strip
        end

        def made
          A.build
        end

        def qualified
          Ns::A.build
        end

        def unknown_class
          File.build
        end

        def chained
          A.build.strip
        end
      end
    end

    class C
      include Helpers

      def run
        helper
      end
    end

    module Helpers
      def helper
        BODY
      end
    end
  RUBY

  def test_a_call_on_a_receiver_of_unknown_class_is_not_an_edge
    with_repo do |repo|
      repo.write("lib/ns.rb", RECEIVERS.gsub("BODY", "1"))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/ns.rb", RECEIVERS.gsub("BODY", "2"))
      repo.commit("Change the leaves.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      callers = doc["methods"].to_h { |method| [method["name"], method["callsites"].map { |site| site["enclosing"] }.sort] }

      assert_equal %w[Ns::A#again Ns::A#mine Ns::A.sample Ns::B#fresh], callers.fetch("Ns::A#strip")
      assert_equal %w[Ns::A#remake Ns::B#chained Ns::B#made Ns::B#qualified], callers.fetch("Ns::A.build")
      assert_equal %w[C#run], callers.fetch("Helpers#helper")
    end
  end

  def test_an_instance_variable_built_from_one_class_is_that_class
    with_repo do |repo|
      leaf = "class Repo\n  def read\n    BODY\n  end\nend\n\nclass Other\n  def read\n    0\n  end\nend\n"
      users = <<~SRC
        class Store
          def initialize(repo)
            @repo = repo.is_a?(Repo) ? repo : Repo.new(repo)
            @either = rand > 0.5 ? Repo.new : Other.new
            @tested = Other.new ? Repo.new : nil
            @given = repo
          end

          def load
            @repo.read
          end

          def mixed
            @either.read
          end

          def passed
            @given.read
          end

          def tested
            @tested.read
          end
        end
      SRC
      repo.write("lib/repo.rb", leaf.sub("BODY", "1"))
      repo.write("lib/store.rb", users)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/repo.rb", leaf.sub("BODY", "2"))
      repo.commit("Change read.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["Repo#read", ["Store#load", "Store#tested"]]], doc["methods"].map { |method| method.values_at("name", "reachable_from") }
    end
  end

  def test_a_local_variable_built_from_one_class_in_its_method_is_that_class
    with_repo do |repo|
      leaf = "class Repo\n  def read\n    BODY\n  end\nend\n\nclass Other\n  def read\n    0\n  end\nend\n"
      users = <<~SRC
        class Store
          def load
            repo = Repo.new
            repo.read
          end

          def mixed(flag)
            repo = flag ? Repo.new : Other.new
            repo.read
          end

          def reassigned(given)
            repo = Repo.new
            repo = given
            repo.read
          end

          def elsewhere
            repo.read
          end

          def repo = Other.new

          def in_a_block
            [1].map { found = Repo.new; found.read }
          end
        end
      SRC
      repo.write("lib/repo.rb", leaf.sub("BODY", "1"))
      repo.write("lib/store.rb", users)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/repo.rb", leaf.sub("BODY", "2"))
      repo.commit("Change read.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["Repo#read", ["Store#in_a_block", "Store#load"]]], doc["methods"].map { |method| method.values_at("name", "reachable_from") }
    end
  end

  def test_a_self_call_does_not_reach_another_class_method_or_past_an_attribute
    with_repo do |repo|
      leaf = "class Runner\n  def self.simulate\n    BODY\n  end\n\n  def label\n    BODY\n  end\n\n  def size\n    BODY\n  end\nend\n"
      users = <<~SRC
        class Mismatch
          attr_reader :label

          def to_s
            simulate
          end

          def name
            label
          end

          def count
            size
          end
        end
      SRC
      repo.write("lib/runner.rb", leaf.gsub("BODY", "1"))
      repo.write("lib/mismatch.rb", users)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/runner.rb", leaf.gsub("BODY", "2"))
      repo.commit("Change the runner.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      callers = doc["methods"].to_h { |method| [method["name"], method["callsites"].map { |site| site["enclosing"] }] }

      assert_equal({ "Runner.simulate" => [], "Runner#label" => [], "Runner#size" => ["Mismatch#count"] }, callers)
    end
  end

  def test_parse_errors_and_oversized_files_are_not_indexed
    with_repo do |repo|
      big = "class Big\n  def size\n    1\n  end\nend\n#{"#" * 200_001}\n"
      repo.write("lib/big.rb", big)
      repo.write("lib/ok.rb", "class Ok\n  def n\n    1\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/big.rb", big.sub("    1\n", "    2\n"))
      repo.write("lib/ok.rb", "class Ok\n  def n\n    2\n  end\n")
      repo.commit("Break ok.rb.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["head", "lib/ok.rb"]], doc["parse_errors"].map { |err| err.values_at("ref", "file") }
      refute_empty doc["parse_errors"].fetch(0)["message"]
      assert_equal [["Ok#n", "removed"]], doc["methods"].map { |method| method.values_at("name", "change") }
    end
  end

  def test_constants_test_files_and_the_grep_of_tests
    with_repo do |repo|
      shop = <<~RUBY
        class Shop
          LIMIT = 3
          RATE = 8
          OLD = 1

          def tax
            RATE
          end

          def price
            LIMIT + 1
          end

          def cap
            LIMIT
          end

          def id
            LIMIT
          end
        end
      RUBY
      repo.write("lib/shop.rb", shop)
      repo.write("lib/other.rb", "module Other\n  KEEP = 1\nend\n")
      repo.write("lib/notes.rb", "# price tax\n")
      repo.write("spec/shop_spec.rb", "Shop.new.price\nShop.new.tax\nShop.new.id\n")
      repo.write("price_test.rb", "price\n")
      repo.write("test/reader.rb", "def limit_reader\n  Shop::LIMIT\nend\n")
      repo.write("test/unrelated_test.rb", "nothing here\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/shop.rb", shop.sub("LIMIT = 3", "LIMIT = 4").sub("  OLD = 1\n", "  NEW = 2\n").sub("    LIMIT + 1\n", "    LIMIT + 2\n"))
      repo.write("test_price.rb", "Shop.new.price\n")
      repo.commit("Raise LIMIT.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      constants = doc["constants"].map { |const| const.values_at("name", "change") }
      methods = doc["methods"].to_h { |method| [method["name"], method] }

      assert_equal [["Shop::LIMIT", "modified"], ["Shop::NEW", "added"], ["Shop::OLD", "removed"]], constants.sort
      assert_equal [["Shop#cap", "affected"], ["Shop#id", "affected"], ["Shop#price", "modified"]],
        methods.values.map { |method| method.values_at("name", "change") }.sort
      assert_nil methods.fetch("Shop#price")["via_constant"]
      assert_equal %w[price_test.rb spec/shop_spec.rb test_price.rb], methods["Shop#price"]["existing_tests"].map { |hit| hit["file"] }
      assert_equal [], methods.fetch("Shop#id")["existing_tests"]
    end
  end

  def test_coverage_lines_bound_a_method_and_the_file_must_be_well_formed
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def a\n    1\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", "class Calc\n  def a\n    2\n  end\n\n  def b\n    3\n  end\nend\n")
      repo.commit("Add b.", date: "2026-02-12T00:00:00Z")
      coverage = File.join(repo.dir, "coverage.json")
      write = ->(tests) { File.write(coverage, JSON.generate({ "format" => "jitcatch-coverage-v1", "tests" => tests })) }
      write.call([
        { "id" => "T#start", "file" => "t.rb", "lines" => { "lib/calc.rb" => [2] } },
        { "id" => "T#end", "file" => "t.rb", "lines" => { "lib/calc.rb" => [4] } },
        { "id" => "T#before", "file" => "t.rb", "lines" => { "lib/calc.rb" => [1] } },
        { "id" => "T#after", "file" => "t.rb", "lines" => { "lib/calc.rb" => [5, "2"] } },
        { "id" => "T#other", "file" => "t.rb", "lines" => { "lib/other.rb" => [2] } },
        { "id" => "T#flat", "file" => "t.rb", "lines" => { "lib/calc.rb" => 2 } },
        { "id" => "T#b", "file" => "u.rb", "lines" => { "lib/calc.rb" => [7] } }
      ])

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD", coverage: coverage)
      hits = doc["methods"].to_h { |method| [method["name"], method["existing_tests"].map { |hit| hit["test"] }] }
      assert_equal({ "Calc#a" => ["T#end", "T#start"], "Calc#b" => ["T#b"] }, hits)

      {
        nil => "coverage file not found: ",
        "{" => "coverage file is not JSON: ",
        JSON.generate({ "format" => "other", "tests" => [] }) => "coverage file must be JSON object",
        JSON.generate({ "format" => "jitcatch-coverage-v1" }) => "coverage file must be JSON object",
        JSON.generate({ "format" => "jitcatch-coverage-v1", "tests" => [1] }) => "coverage test entries must be objects"
      }.each do |body, message|
        body.nil? ? File.delete(coverage) : File.write(coverage, body)
        error = assert_raises(JitCatch::UsageError) { JitCatch::Changes.between(repo.dir, "base", "HEAD", coverage: coverage) }
        assert error.message.start_with?(message), error.message
      end
    end
  end

  def test_entrypoints_list_changed_methods_first_and_a_removed_class_from_base
    with_repo do |repo|
      repo.write("lib/keep.rb", "class Keep\n  def z\n    1\n  end\n\n  def a\n    1\n  end\n\n  private\n\n  def hidden\n    1\n  end\nend\n")
      repo.write("lib/drop.rb", "class Drop\n  def run\n    1\n  end\nend\n")
      repo.write("lib/top.rb", "def helper\n  1\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/keep.rb", "class Keep\n  def z\n    2\n  end\n\n  def a\n    1\n  end\n\n  private\n\n  def hidden\n    2\n  end\nend\n")
      FileUtils.rm(File.join(repo.dir, "lib/drop.rb"))
      repo.write("lib/top.rb", "def helper\n  2\nend\n")
      repo.commit("Change z, hidden, helper; drop Drop.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal({
        "Drop" => [["Drop#run", "removed"]],
        "Keep" => [["Keep#z", "modified"], ["Keep#a", "unchanged"]]
      }, doc["entrypoints"].to_h { |entry| [entry["class"], entry["methods"].map { |method| method.values_at("name", "role") }] })
    end
  end
end
