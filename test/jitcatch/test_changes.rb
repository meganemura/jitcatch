# frozen_string_literal: true

require_relative "../test_helper"

class TestChanges < Minitest::Test
  BOX = <<~RUBY
    class Box
      LIMIT = 10

      def price
        return 0 if n < LIMIT
        5
      end

      def n
        10
      end
    end
  RUBY

  def test_constant_change_marks_reader_as_affected
    with_repo do |repo|
      repo.write("lib/box.rb", BOX)
      repo.write("test/box_test.rb", "def test_price; price; end\n")
      repo.commit("Initial box", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/box.rb", BOX.sub("LIMIT = 10", "LIMIT = 5"))
      repo.commit("Lower LIMIT from 10 to 5.\n\nIntentional.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      text = JitCatch::Render.context_text(doc)
      assert_equal text, JitCatch::Render.context_text(JitCatch::Changes.between(repo.dir, "base", "HEAD"))
      refute_match(/\d{4}-\d{2}-\d{2}T/, text)
      refute_match(/Finished in/, text)

      assert_equal ["Lower LIMIT from 10 to 5.", "Intentional."], doc["intent"]
      assert_equal "grep", doc["existing_tests_via"]
      const = doc["constants"].fetch(0)
      assert_equal "k01", const["id"]
      assert_equal "modified", const["change"]
      assert_equal "Box::LIMIT", const["name"]
      assert_equal "LIMIT = 10", const["old_source"]
      assert_equal "LIMIT = 5", const["new_source"]

      price = doc["methods"].find { |method| method["bare_name"] == "price" }
      assert_equal "affected", price["change"]
      assert_equal "m01", price["id"]
      assert_equal const["id"], price["via_constant"]
      assert_equal price["old_source"], price["new_source"]
      assert_includes price["existing_tests"].map { |test| test["file"] }, "test/box_test.rb"
      assert_includes text, "[#{price["id"]}] affected Box#price"
      assert_includes text, "LIMIT = 5"

      roles = doc["entrypoints"].fetch(0)["methods"].to_h { |method| [method["name"], method["role"]] }
      assert_equal "affected", roles["Box#price"]
      assert_equal "unchanged", roles["Box#n"]

      coverage = File.join(repo.dir, "coverage.json")
      File.write(coverage, JSON.generate({
        "format" => "jitcatch-coverage-v1",
        "tests" => [{
          "id" => "BoxTest#test_price",
          "file" => "test/box_test.rb",
          "lines" => { "lib/box.rb" => [price["start_line"]] }
        }]
      }))
      covered = JitCatch::Changes.between(repo.dir, "base", "HEAD", coverage: coverage)
      hit = covered["methods"].find { |method| method["bare_name"] == "price" }["existing_tests"]
      assert_equal [{ "file" => "test/box_test.rb", "test" => "BoxTest#test_price", "via" => "coverage" }], hit
      assert_equal "coverage", covered["existing_tests_via"]
    end
  end

  def test_intent_leaves_out_each_commit_trailer_block
    with_repo do |repo|
      repo.write("lib/box.rb", BOX)
      repo.commit("Initial box", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/box.rb", BOX.sub("LIMIT = 10", "LIMIT = 5"))
      repo.commit(<<~MSG, date: "2026-02-12T00:00:00Z")
        Lower LIMIT.

        Note: this paragraph is not the last one.

        Co-Authored-By: Pair <pair@example.local>
        Session: https://example.local/1
      MSG
      repo.write("lib/box.rb", BOX.sub("LIMIT = 10", "LIMIT = 4"))
      repo.commit("Lower it again.\n\nReviewed-by: Rev <rev@example.local>\n", date: "2026-02-13T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal ["Lower LIMIT.", "Note: this paragraph is not the last one.", "---", "Lower it again."], doc["intent"]
    end
  end

  def test_a_method_no_test_names_lists_the_tests_of_its_public_entry_points
    with_repo do |repo|
      cart = <<~RUBY
        class Cart
          LIMIT = 3

          def total
            subtotal + fee
          end

          def subtotal
            10
          end

          private

          def fee
            1
          end
        end
      RUBY
      repo.write("lib/cart.rb", cart)
      repo.write("test/cart_test.rb", "Cart.new.total\n")
      repo.write("test/other_test.rb", "Other.new.total\n")
      repo.write("test/limit_test.rb", "Cart::LIMIT\nbox.total\n")
      repo.write("test/subtotal_test.rb", "Cart.new.subtotal\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/cart.rb", cart.sub("    1\n", "    2\n").sub("    10\n", "    11\n"))
      repo.commit("Raise the fee and the subtotal.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      by_name = doc["methods"].to_h { |method| [method["name"], method] }
      fee = by_name.fetch("Cart#fee")
      subtotal = by_name.fetch("Cart#subtotal")

      assert_equal [], fee["existing_tests"]
      assert_equal ["Cart#total"], fee["reachable_from"]
      assert_equal [{ "file" => "test/cart_test.rb", "entry_points" => ["Cart#total"] }], fee["entry_point_tests"]
      assert_equal [{ "file" => "test/subtotal_test.rb", "via" => "grep" }], subtotal["existing_tests"]
      assert_equal [], subtotal["entry_point_tests"]
      text = JitCatch::Render.context_text(doc)
      assert_includes text, "    tests: (none)\n    entry_point_tests: test/cart_test.rb via Cart#total\n"

      coverage = File.join(repo.dir, "coverage.json")
      File.write(coverage, JSON.generate({ "format" => "jitcatch-coverage-v1", "tests" => [] }))
      covered = JitCatch::Changes.between(repo.dir, "base", "HEAD", coverage: coverage)
      assert_equal [], covered["methods"].find { |method| method["name"] == "Cart#fee" }["entry_point_tests"]
    end
  end

  def test_method_edit_includes_old_and_new_source_and_callsites
    with_repo do |repo|
      repo.write("lib/calc.rb", <<~RUBY)
        class Calc
          def total(n)
            double(n)
          end

          def double(n)
            n * 2
          end
        end
      RUBY
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", <<~RUBY)
        class Calc
          def total(n)
            double(n)
          end

          def double(n)
            n * 2 + 1
          end

          def extra(n)
            total(n)
          end
        end
      RUBY
      repo.commit("Add extra.\n\nDouble stays the same.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      names = doc["methods"].to_h { |method| [method["name"], method] }
      assert_equal %w[added modified], names.values.map { |method| method["change"] }.sort
      assert_equal "modified", names["Calc#double"]["change"]
      assert_equal "same", names["Calc#double"]["signature"]
      assert_includes names["Calc#double"]["old_source"], "n * 2"
      assert_includes names["Calc#double"]["new_source"], "n * 2 + 1"
      assert_equal ["lib/calc.rb"], names["Calc#double"]["callsites"].map { |site| site["file"] }.uniq
      assert_includes names["Calc#double"]["callsites"].map { |site| site["enclosing"] }, "Calc#total"
      assert_equal "added", names["Calc#extra"]["change"]
      assert_equal "added", names["Calc#extra"]["signature"]
      assert_nil names["Calc#extra"]["old_source"]
      refute names.key?("Calc#total")
    end
  end

  def test_a_class_or_module_that_only_one_side_defines_is_a_constant
    with_repo do |repo|
      repo.write("lib/model.rb", <<~RUBY)
        class Model
          class Unsupported < StandardError; end

          def check(op)
            raise Unsupported, op unless op == "+"
          end
        end
      RUBY
      repo.write("lib/extra.rb", "class Model\n  def extra\n    1\n  end\nend\n")
      repo.write("lib/label.rb", "class Label\n  def text\n    \"Ops Unsupported\"\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/model.rb", <<~RUBY)
        class Model
          module Ops
          end

          def check(op)
            raise ArgumentError, op unless op == "+"
          end
        end
      RUBY
      repo.write("lib/more.rb", "class Model\n  def more\n    2\n  end\nend\n")
      repo.commit("Drop Unsupported.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal [["added", "Model::Ops", "module Ops"], ["removed", "Model::Unsupported", "class Unsupported < StandardError; end"]],
        doc["constants"].map { |const| [const["change"], const["name"], const["old_source"] || const["new_source"]] }
      assert_equal [["Model#check", "modified"], ["Model#more", "added"]], doc["methods"].map { |method| method.values_at("name", "change") },
        "a method that only names a namespace is not affected"
      check = doc["methods"].find { |method| method["name"] == "Model#check" }
      assert_equal [check["id"]], doc["constants"].find { |const| const["name"] == "Model::Unsupported" }["readers"]
    end
  end

  def test_the_parent_of_the_root_commit_is_the_empty_tree
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      repo.commit("Add Calc.", date: "2026-02-11T00:00:00Z")

      %w[HEAD^ HEAD~ HEAD~1 HEAD^1].each do |base|
        doc = JitCatch::Changes.between(repo.dir, base, "HEAD")
        assert_equal ["Add Calc."], doc["intent"]
        assert_equal [["A", "lib/calc.rb"]], doc["files"].map { |file| file.values_at("status", "file") }
        assert_equal [["Calc#add", "added"]], doc["methods"].map { |method| method.values_at("name", "change") }
      end
      assert_raises(JitCatch::GitError) { JitCatch::Changes.between(repo.dir, "HEAD~2", "HEAD") }
      assert_raises(JitCatch::GitError) { JitCatch::Changes.between(repo.dir, "nope^", "HEAD") }

      tests = File.join(repo.dir, "candidates")
      write_tests(tests, { "calc_test.rb" => "require \"minitest/autorun\"\nrequire \"calc\"\nclass CalcTest < Minitest::Test\n  def test_add\n    assert_equal 3, Calc.new.add(1, 2)\n  end\nend\n" })
      run = JitCatch::Runner.run(repo.dir, "HEAD^", "HEAD", tests, reruns: 0)
      assert_equal [["calc_test.rb#load", "fail_on_base"]], run["tests"].map { |test| test.values_at("name", "classification") }
    end
  end

  def test_a_base_that_is_not_an_ancestor_of_head_is_named_in_a_warning
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      fork = repo.commit("Add Calc.", date: "2026-02-11T00:00:00Z")
      repo.branch("side")
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b + 0\n  end\nend\n")
      repo.commit("Pad add.", date: "2026-02-12T00:00:00Z")
      repo.checkout("side")
      repo.write("lib/other.rb", "class Other\nend\n")
      repo.commit("Add Other.", date: "2026-02-13T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "side", "main")
      assert_equal [
        "base is not an ancestor of head: the diff also undoes the 1 commit only base has. " \
        "Pass `git merge-base BASE HEAD` (#{fork[0, 12]}) as BASE to review head's commits alone."
      ], doc["warnings"]
      assert_includes JitCatch::Render.context_text(doc), "\nwarning: base is not an ancestor of head"
      assert_equal [], JitCatch::Changes.between(repo.dir, fork, "main")["warnings"]
      assert_equal ["base and head are the same commit, so the diff is empty. Pass the parent of the change as BASE."],
        JitCatch::Changes.between(repo.dir, "main", "main")["warnings"]
      assert_equal [], JitCatch::Changes.between(repo.dir, "main^^", "main")["warnings"]
      repo.git("checkout", "--orphan", "alone")
      repo.commit("Start over.", date: "2026-02-14T00:00:00Z")
      assert_equal [
        "base is not an ancestor of head: the diff also undoes the 2 commits only base has. The two revisions share no history."
      ], JitCatch::Changes.between(repo.dir, "main", "alone")["warnings"]
    end
  end

  def test_dependencies_come_from_the_gemfile_lock_diff
    lock = lambda do |specs|
      "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs.map { |spec| "    #{spec}\n      dep (>= 0)\n" }.join}\nPLATFORMS\n  ruby\n\nBUNDLED WITH\n   2.6.0\n"
    end
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      repo.write("Gemfile.lock", lock.call(["rack (3.0.0)", "gone (1.0)", "same (2.0)", "nokogiri (1.16.0-x86_64-linux)"]))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("Gemfile.lock", lock.call(["rack (3.1.0)", "fresh (0.1)", "same (2.0)", "nokogiri (1.16.0-x86_64-linux)", "nokogiri (1.16.0-arm64-darwin)"]))
      repo.commit("Bump rack.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal [
        { "gem" => "fresh", "old" => nil, "new" => "0.1" },
        { "gem" => "gone", "old" => "1.0", "new" => nil },
        { "gem" => "nokogiri", "old" => "1.16.0-x86_64-linux", "new" => "1.16.0-arm64-darwin 1.16.0-x86_64-linux" },
        { "gem" => "rack", "old" => "3.0.0", "new" => "3.1.0" }
      ], doc["dependencies"]
      text = JitCatch::Render.context_text(doc)
      assert_includes text, "dependencies:\n  fresh (none) -> 0.1\n  gone 1.0 -> (none)\n"
      assert_includes text, "  rack 3.0.0 -> 3.1.0\nconstants: (none)\n"

      assert_equal [], JitCatch::Changes.between(repo.dir, "base", "base")["dependencies"]
      refute_includes JitCatch::Render.context_text(JitCatch::Changes.between(repo.dir, "base", "base")), "dependencies"
    end
  end

  def test_a_file_over_the_blob_cap_is_not_indexed_and_a_non_ascii_path_is
    with_repo do |repo|
      big = ->(body) { "class Big\n  def size\n    #{body}\n  end\nend\n#{"# pad\n" * 40_000}" }
      repo.write("lib/big.rb", big.call(1))
      repo.write("lib/café.rb", "class Cafe\n  def price\n    1\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/big.rb", big.call(2))
      repo.write("lib/café.rb", "class Cafe\n  def price\n    2\n  end\nend\n")
      repo.commit("Raise both.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_operator File.size(File.join(repo.dir, "lib/big.rb")), :>, JitCatch::Changes::MAX_BLOB
      assert_equal [["Cafe#price", "lib/café.rb"]], doc["methods"].map { |method| method.values_at("name", "file") }
    end
  end

  def test_methods_in_test_files_are_not_listed
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      repo.write("test/calc_test.rb", "class CalcTest\n  def test_add\n    Calc.new.add(1, 2)\n  end\nend\n")
      repo.write("spec/support/build.rb", "def build_calc\n  Calc.new\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    b + a\n  end\nend\n")
      repo.write("test/calc_test.rb", "class CalcTest\n  def test_add\n    Calc.new.add(2, 1)\n  end\nend\n")
      repo.write("spec/support/build.rb", "def build_calc\n  Calc.new.freeze\nend\n")
      repo.commit("Swap operands.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal ["Calc#add"], doc["methods"].map { |method| method["name"] }
      assert_equal ["Calc"], doc["entrypoints"].map { |entry| entry["class"] }
      assert_equal ["test/calc_test.rb"], doc["methods"].fetch(0)["existing_tests"].map { |hit| hit["file"] }
    end
  end

  def test_constants_classes_and_reopened_methods_in_test_files_are_not_listed
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  LIMIT = 1\n\n  def add(a, b)\n    a + b\n  end\nend\n")
      repo.write("test/fixtures/stub.rb", "STUB = 1\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", "class Calc\n  LIMIT = 2\n\n  def add(a, b)\n    b + a\n  end\nend\n")
      repo.write("test/fixtures/stub.rb", "STUB = 2\n")
      repo.write("test/calc_test.rb", "class CalcTest\n  WANT = 3\nend\n\nclass Calc\n  def debug_add\n    add(1, 2)\n  end\nend\n")
      repo.commit("Swap operands.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal ["Calc::LIMIT"], doc["constants"].map { |const| const["name"] }
      assert_equal ["Calc#add"], doc["entrypoints"].flat_map { |entry| entry["methods"].map { |method| method["name"] } }
    end
  end

  def test_a_private_constant_hides_the_methods_another_file_defines_under_it
    with_repo do |repo|
      repo.write("lib/shop.rb", "module Shop\n  private_constant :Ledger\nend\n")
      repo.write("lib/shop/ledger.rb", "module Shop\n  class Ledger\n    def post\n      1\n    end\n  end\n\n  class Till\n    def open\n      1\n    end\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/shop/ledger.rb", "module Shop\n  class Ledger\n    def post\n      2\n    end\n  end\n\n  class Till\n    def open\n      2\n    end\n  end\nend\n")
      repo.commit("Post two.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal({ "Shop::Ledger#post" => "private", "Shop::Till#open" => "public" },
        doc["methods"].to_h { |method| [method["name"], method["visibility"]] })
      assert_equal ["Shop::Till"], doc["entrypoints"].map { |entry| entry["class"] }
    end
  end

  def test_reachable_from_keeps_the_nearest_callers_when_it_is_cut
    with_repo do |repo|
      near = (1..6).map { |n| "  def z#{n}\n    leaf\n  end\n" }.join("\n")
      far = (1..4).map { |n| "  def a#{n}\n    z1\n  end\n" }.join("\n")
      repo.write("lib/tree.rb", "class Tree\n  def leaf\n    1\n  end\n\n#{near}\n#{far}end\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/tree.rb", "class Tree\n  def leaf\n    2\n  end\n\n#{near}\n#{far}end\n")
      repo.commit("Change the leaf.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal %w[Tree#a1 Tree#a2 Tree#z1 Tree#z2 Tree#z3 Tree#z4 Tree#z5 Tree#z6],
        doc["methods"].find { |method| method["name"] == "Tree#leaf" }["reachable_from"]
    end
  end

  def test_attribute_readers_and_struct_members_are_methods_and_new_is_an_entry_point
    with_repo do |repo|
      repo.write("lib/mismatch.rb", <<~RUBY)
        class Mismatch < StandardError
          attr_reader :reason, :trace
          attr_accessor :seed

          def initialize(reason = nil)
            super
          end

          def to_s = super
        end

        Rule = Struct.new(:action, :args)
        Pick = Data.define(:name, :value)
      RUBY
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/mismatch.rb", <<~RUBY)
        class Mismatch < StandardError
          attr_reader :trace
          attr_writer :seed

          def to_s = super
        end

        Rule = Struct.new(:action, :args, :fixed)
        Pick = Data.define(:name)
      RUBY
      repo.commit("Drop the reason.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      changes = doc["methods"].map { |method| method.values_at("name", "change", "signature") }
      assert_equal [
        ["Mismatch#initialize", "removed", "removed"],
        ["Mismatch#reason", "removed", "removed"],
        ["Mismatch#seed", "removed", "removed"],
        ["Pick#value", "removed", "removed"],
        ["Rule#fixed", "added", "added"],
        ["Rule#fixed=", "added", "added"]
      ], changes
      reason = doc["methods"].find { |method| method["name"] == "Mismatch#reason" }
      assert_equal ["attr_reader :reason", 2], reason.values_at("old_source", "old_start")
      entries = doc["entrypoints"].to_h { |entry| [entry["class"], entry["methods"].map { |method| method.values_at("name", "role") }] }
      assert_equal [["Mismatch.new", "removed"], ["Mismatch#seed=", "unchanged"], ["Mismatch#to_s", "unchanged"], ["Mismatch#trace", "unchanged"]], entries["Mismatch"]
      assert_equal [["Pick#name", "unchanged"]], entries["Pick"]
      assert_equal [["Rule#fixed", "added"], ["Rule#fixed=", "added"], ["Rule#action", "unchanged"]], entries["Rule"].first(3)
    end
  end

  def test_a_method_that_only_turns_private_is_modified
    with_repo do |repo|
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\n\n  def sub(a, b)\n    a - b\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\n\n  private\n\n  def sub(a, b)\n    a - b\n  end\nend\n")
      repo.commit("Hide sub.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["Calc#sub", "modified", "same", "private"]], doc["methods"].map { |method| method.values_at("name", "change", "signature", "visibility") }
    end
  end

  def test_whole_files_added_and_removed_and_a_changed_signature
    with_repo do |repo|
      repo.write("lib/old.rb", "module Old\n  LIMIT = 1\n\n  def self.gone\n    LIMIT\n  end\nend\n")
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      FileUtils.rm(File.join(repo.dir, "lib/old.rb"))
      repo.write("lib/new.rb", "module New\n  LIMIT = 2\nend\n")
      repo.write("lib/calc.rb", "class Calc\n  def add(a, b, c)\n    a + b + c\n  end\nend\n")
      repo.commit("Replace Old with New.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      assert_equal [["k01", "added", "New"], ["k02", "added", "New::LIMIT"], ["k03", "removed", "Old"], ["k04", "removed", "Old::LIMIT"]],
        doc["constants"].map { |const| const.values_at("id", "change", "name") }
      assert_equal [["Calc#add", "modified", "changed"], ["Old.gone", "removed", "removed"]],
        doc["methods"].map { |method| method.values_at("name", "change", "signature") }
      assert_equal [["A", "lib/new.rb"], ["D", "lib/old.rb"], ["M", "lib/calc.rb"]].sort_by(&:last),
        doc["files"].map { |file| file.values_at("status", "file") }
    end
  end
end
