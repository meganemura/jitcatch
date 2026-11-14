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

  def test_a_method_moved_to_another_file_is_moved_not_removed
    with_repo do |repo|
      repo.write("script/mismatch.rb", "class Always\n  def cents(n) = 0\nend\n\nclass Fake\n  def name = \"x\"\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("script/mismatch.rb", "# moved\n")
      repo.write("test/always.rb", "class Always\n  def cents(n) = 1\nend\n")
      repo.write("lib/fake.rb", "class Fake\n  def name = \"x\"\n  def size = 1\nend\n")
      repo.commit("Move the doubles.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      rows = doc["methods"].map { |method| method.values_at("name", "change", "file", "moved_from", "signature") }

      assert_equal [["Always#cents", "moved", "test/always.rb", "script/mismatch.rb", "same"], ["Fake#name", "moved", "lib/fake.rb", "script/mismatch.rb", "same"], ["Fake#size", "added", "lib/fake.rb", nil, "added"]], rows.sort
      assert_includes JitCatch::Render.context_text(doc), "moved Always#cents test/always.rb:2-2 signature=same visibility=public moved_from=script/mismatch.rb\n"
    end
  end

  CALC_BASE = <<~RUBY
    class Calc
      def total(net, volume)
        net - volume
      end
      # note

      def label
        "x"
      end

      def wide(n)
        n + 1
      end

      def shrink(n)
        a = n
        b = a
        b
      end

      def deleting(n)
        n += 1
        b = n
        b
      end

      def helper = 1
    end
  RUBY

  CALC_HEAD = <<~RUBY
    class Calc
      def total(net, volume)
        net - volume - coupon
      end

      def label
        "y"
      end

      def wide(n)
        x = n + coupon
        x + helper
      end

      def shrink(n)
        n - coupon
      end

      def deleting(n)
        b = n
        b + coupon
      end

      def helper = 1
      def coupon = 2
    end
  RUBY

  # Only an edit whose every new line calls the added method, and that
  # removes no more lines than it writes, forwards to it.
  def test_an_edit_forwards_to_an_added_method_only_when_it_only_adds_that_call
    with_repo do |repo|
      repo.write("lib/calc.rb", CALC_BASE)
      repo.write("lib/old.rb", "class Old\n  def x = 1\nend\n")
      repo.write("lib/trim.rb", "class Trim\n  def x = 1\n  def y = 2\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/calc.rb", CALC_HEAD)
      repo.write("lib/side.rb", "class Calc\n  def side\n    1\n  end\n\n  def side2\n    coupon\n  end\nend\n")
      repo.git("rm", "-q", "lib/old.rb")
      repo.write("lib/trim.rb", "class Trim\n  def x = 1\nend\n")
      repo.commit("Add a coupon.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      forwards = doc["methods"].select { |method| method["change"] == "modified" }.to_h { |method| [method["bare_name"], method["forwards_to_added"]] }

      assert_equal({ "deleting" => false, "label" => false, "shrink" => false, "total" => true, "wide" => false }, forwards.sort.to_h)
      assert_equal({ "lib/calc.rb" => [[3, 3], [7, 7], [11, 12], [16, 16], [21, 21], [25, 25]], "lib/side.rb" => [[1, 9]] }, doc["changed_lines"])
    end
  end

  # Only an edit inside the arguments of a raise leaves when the method
  # raises as it was. One to the guard beside the raise, on the same line,
  # does not.
  def test_an_edit_changes_only_a_raise_when_the_rest_of_the_method_is_the_same
    base = <<~RUBY
      class Gate
        def refuse(what)
          raise ArgumentError, "no \#{what}"
        end

        def check(n)
          fail ArgumentError, "low" if n < 0
          n
        end

        def wide(n)
          raise ArgumentError, "low" if n < 0
          n
        end
      end
    RUBY
    head = base.sub('"no #{what}"', '"no #{what}", caller_locations')
               .sub('fail ArgumentError, "low" if n < 0', 'fail ArgumentError, "too low" if n < 0')
               .sub('raise ArgumentError, "low" if n < 0', 'raise ArgumentError, "low" if n < -1')
    with_repo do |repo|
      repo.write("lib/gate.rb", base)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/gate.rb", head)
      repo.commit("Say where a refusal came from.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      only = doc["methods"].to_h { |method| [method["bare_name"], method["edits_only_raise"]] }

      assert_equal({ "check" => true, "refuse" => true, "wide" => false }, only)
    end
  end

  # An executable's top-level code is a method of its own, so a change to
  # its usage text is listed, with the tests that start it by its path. An
  # edit inside one of its defs is that def's, and a shell script is not read.
  def test_the_top_level_code_of_an_executable_is_a_method
    tool = <<~RUBY
      #!/usr/bin/env ruby
      require_relative "../lib/tool"

      def usage = "usage: tool run"

      case ARGV.first
      when "run" then puts Tool.run
      else warn usage
      end
    RUBY
    with_repo do |repo|
      repo.write("lib/tool.rb", "module Tool\n  def self.run = 1\nend\n")
      repo.write("exe/tool", tool)
      repo.write("bin/setup", "#!/bin/sh\necho ok\n")
      repo.write("test/tool_test.rb", "class ToolTest\n  def test_usage = system(\"exe/tool\")\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      helped = tool.sub("then puts Tool.run", "then puts Tool.run\nwhen \"help\" then puts usage")
      repo.write("exe/tool", helped)
      repo.write("bin/setup", "#!/bin/sh\necho done\n")
      repo.commit("Add help.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      main = doc["methods"].find { |method| method["name"] == "exe/tool <main>" }

      assert_equal [["exe/tool <main>"]], doc["methods"].map { |method| [method["name"]] }
      assert_equal ["modified", "script", 2, 10], main.values_at("change", "kind", "start_line", "end_line")
      assert_equal [{ "file" => "test/tool_test.rb", "via" => "grep" }], main["existing_tests"]

      repo.write("exe/tool", helped.sub("usage: tool run", "usage: tool run|help"))
      repo.commit("Name help.", date: "2026-02-13T00:00:00Z")
      names = JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")["methods"].map { |method| method["name"] }
      assert_equal ["#usage"], names
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

  # Rails models name their state changes `approve!` and their questions
  # `approved?`; a word boundary after `!` or `?` never matches.
  def test_a_bang_or_predicate_method_finds_the_tests_that_call_it
    with_repo do |repo|
      loan = <<~RUBY
        class Loan
          def approve!
            approved? ? :again : save!
          end

          def approved?
            false
          end

          def save!
            :saved
          end

          def review
            approve!
          end
        end
      RUBY
      repo.write("app/models/loan.rb", loan)
      repo.write("spec/models/loan_spec.rb", "loan = create(:loan)\nloan.approve!\nexpect(loan.approved?).to be true\n")
      repo.write("spec/models/review_spec.rb", "Loan.new.review\n")
      repo.write("spec/models/approve_spec.rb", "approve = :symbol_only\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("app/models/loan.rb", loan.sub(":saved", ":stored").sub("approved? ? :again", "approved? ? :twice").sub("    false\n", "    nil\n"))
      repo.commit("Store loans.", date: "2026-02-12T00:00:00Z")

      by_name = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].to_h { |method| [method["name"], method] }

      assert_equal ["spec/models/loan_spec.rb"], by_name.fetch("Loan#approve!")["existing_tests"].map { |test| test["file"] }
      assert_equal ["spec/models/loan_spec.rb"], by_name.fetch("Loan#approved?")["existing_tests"].map { |test| test["file"] }
      save = by_name.fetch("Loan#save!")
      assert_equal [], save["existing_tests"]
      assert_equal [{ "file" => "spec/models/review_spec.rb", "entry_points" => ["Loan#review"] }], save["entry_point_tests"]
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

  # A constant that keeps its value in its new file changes nothing a
  # reader sees; one that takes a new value on the way still changes it.
  def test_a_constant_moved_to_another_file_is_moved_and_affects_no_reader
    with_repo do |repo|
      shop = "module Shop\n  VERSION = \"1.0\"\n  LIMIT = 10\n\n  def self.banner = \"Shop \#{VERSION}\"\n  def self.cap = LIMIT\nend\n"
      repo.write("lib/shop.rb", shop)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/shop.rb", shop.sub("  VERSION = \"1.0\"\n  LIMIT = 10\n", "  require_relative \"shop/version\"\n"))
      repo.write("lib/shop/version.rb", "module Shop\n  VERSION = \"1.0\"\n  LIMIT = 5\nend\n")
      repo.commit("Move the constants to their own file.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["k01", "modified", "Shop::LIMIT", "lib/shop/version.rb", "lib/shop.rb", ["m01"]], ["k02", "moved", "Shop::VERSION", "lib/shop/version.rb", "lib/shop.rb", []]],
        doc["constants"].map { |const| const.values_at("id", "change", "name", "file", "moved_from", "read_by") }
      assert_equal [["Shop.cap", "affected", "k01"]], doc["methods"].map { |method| method.values_at("name", "change", "via_constant") }
      assert_includes JitCatch::Render.context_text(doc), "  [k02] moved Shop::VERSION lib/shop/version.rb:2 moved_from=lib/shop.rb\n"
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
      assert_equal [check["id"]], doc["constants"].find { |const| const["name"] == "Model::Unsupported" }["read_by"]
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

  # A test database made once from one schema holds neither side's
  # schema after a change to it, so a row can fail on a missing column
  # and read as a regression. Only a helper that calls
  # maintain_test_schema! loads each side's schema as its candidates boot.
  def test_a_change_to_the_database_schema_is_named_in_a_warning
    with_repo do |repo|
      repo.write("db/schema.rb", "ActiveRecord::Schema[8.0].define(version: 1) do\nend\n")
      repo.write("spec/rails_helper.rb", "ENV[\"RAILS_ENV\"] ||= \"test\"\n")
      repo.write("db/animals_migrate/20261101000000_add_animals.rb", "class AddAnimals < ActiveRecord::Migration[8.0]\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.write("db/migrate/20261106000000_add_notify.rb", "class AddNotify < ActiveRecord::Migration[8.0]\nend\n")
      repo.write("db/schema.rb", "ActiveRecord::Schema[8.0].define(version: 2) do\nend\n")
      repo.write("db/animals_structure.sql", "CREATE TABLE animals ();\n")
      repo.write("db/seeds.rb", "\n")
      repo.commit("head", date: "2026-02-12T00:00:00Z")

      changed = "head changes the database schema (db/animals_structure.sql, db/migrate/20261106000000_add_notify.rb, db/schema.rb), " \
                "so each side's test database must hold that side's schema, or a row can fail on the database and not on the code."
      assert_equal [
        "#{changed} spec/rails_helper.rb does not call `ActiveRecord::Migration.maintain_test_schema!`, so no candidate loads either schema: " \
        "pass `--setup 'bin/rails db:create db:schema:load'` to `jitcatch run` to load each side's schema into its own test database before the candidates run."
      ], JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")["warnings"]
      assert_includes JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD", databases: %w[app_test_1 app_test_2])["warnings"].first,
        "load each side's schema into its own test database (base app_test_1, head app_test_2) before the candidates run."
      assert_equal ["#{changed} `--setup` ran `bin/rails db:prepare` in each checkout before the candidates."],
        JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD", setup: "bin/rails db:prepare")["warnings"]

      repo.write("spec/rails_helper.rb", "ENV[\"RAILS_ENV\"] ||= \"test\"\nActiveRecord::Migration.maintain_test_schema!\n")
      repo.commit("Maintain the schema.", date: "2026-02-13T00:00:00Z")
      assert_equal [changed], JitCatch::Changes.between(repo.dir, "HEAD~2", "HEAD")["warnings"]
      assert_equal [], JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")["warnings"]
    end
  end

  # An edit inside a Grape endpoint changes that endpoint, a request spec
  # that sends its verb and path is its test, and a method the endpoint
  # calls is reachable from it, so a request spec reaches that method too.
  def test_a_grape_endpoint_is_a_change_unit_that_request_specs_reach
    api = lambda do |args|
      <<~RUBY
        class Things < Grape::API
          resource :things do
            route_param :id do
              post "/refresh" do
                RefreshWorker.perform_async(#{args})
                status :accepted
              end
            end
          end
        end
      RUBY
    end
    worker = ->(body) { "class RefreshWorker\n  def self.perform_async(args)\n    #{body}\n  end\nend\n" }
    with_repo do |repo|
      repo.write("app/apis/things.rb", api.(%({ "id" => params[:id] })))
      repo.write("app/workers/refresh_worker.rb", worker.("args"))
      repo.write("spec/requests/things_spec.rb", %(RSpec.describe "Things" do\n  it "refreshes" do\n    post "/api/things/\#{thing.id}/refresh"\n  end\nend\n))
      repo.write("spec/requests/others_spec.rb", %(RSpec.describe "Others" do\n  it "lists" do\n    get "/api/things/1/refresh"\n    post "/api/things/refresh"\n  end\nend\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.write("app/apis/things.rb", api.(%({ "id" => params[:id], "notify" => true })))
      repo.commit("Notify on refresh.", date: "2026-02-12T00:00:00Z")
      repo.write("app/workers/refresh_worker.rb", worker.("args.merge(\"at\" => 1)"))
      repo.commit("Stamp the job.", date: "2026-02-13T00:00:00Z")

      endpoint = JitCatch::Changes.between(repo.dir, "HEAD~2", "HEAD~1")["methods"].map { |method| method.values_at("name", "change", "existing_tests") }
      assert_equal [["Things#POST /things/:id/refresh", "modified", [{ "file" => "spec/requests/things_spec.rb", "via" => "grep" }]]], endpoint
      worker_change = JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")["methods"].fetch(0)
      assert_equal ["RefreshWorker.perform_async", ["Things#POST /things/:id/refresh"]], worker_change.values_at("name", "reachable_from")
      assert_equal [{ "file" => "spec/requests/things_spec.rb", "entry_points" => ["Things#POST /things/:id/refresh"] }], worker_change["entry_point_tests"]
    end
  end

  # A controller action's tests are the files whose requests the routes
  # send to it, by helper or by path, and the controller tests that name
  # the controller and call the action; a file that only calls a method of
  # the same name, as `create(:book)` does, is not one. With no route to
  # the action, the name is grepped, so no test is hidden.
  def test_a_controller_action_takes_the_tests_its_routes_send_to_it
    controller = ->(body) { "class BooksController < ApplicationController\n  def create\n    #{body}\n  end\n\n  def archive\n    #{body}\n  end\nend\n" }
    with_repo do |repo|
      repo.write("config/routes.rb", "Rails.application.routes.draw do\n  resources :books, only: :create\n  resources :people, only: :create, controller: :books\nend\n")
      repo.write("app/controllers/books_controller.rb", controller.("1"))
      repo.write("spec/requests/books_spec.rb", %(RSpec.describe "Books" do\n  it "creates" do\n    post books_path, params: { title: "dune" }\n  end\nend\n))
      repo.write("spec/requests/people_spec.rb", %(RSpec.describe "People" do\n  it "creates" do\n    post "/people"\n  end\nend\n))
      repo.write("spec/controllers/books_controller_spec.rb", %(RSpec.describe BooksController do\n  it "creates" do\n    post :create\n  end\nend\n))
      repo.write("spec/models/book_spec.rb", %(RSpec.describe Book do\n  it "saves" do\n    create(:book)\n    archive\n  end\nend\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.write("app/controllers/books_controller.rb", controller.("2"))
      repo.commit("Answer 2.", date: "2026-02-12T00:00:00Z")

      tests = JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")["methods"].to_h { |method| [method["name"], method["existing_tests"]] }
      assert_equal [
        { "file" => "spec/controllers/books_controller_spec.rb", "via" => "route", "calls" => ["post :create"] },
        { "file" => "spec/requests/books_spec.rb", "via" => "route", "calls" => ["POST books_path"] },
        { "file" => "spec/requests/people_spec.rb", "via" => "route", "calls" => ["POST /people"] }
      ], tests["BooksController#create"]
      assert_equal [{ "file" => "spec/models/book_spec.rb", "via" => "grep" }], tests["BooksController#archive"]
      assert_includes JitCatch::Render.context_text(JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")),
        "    tests: spec/controllers/books_controller_spec.rb via post :create; spec/requests/books_spec.rb via POST books_path; spec/requests/people_spec.rb via POST /people\n"
    end
  end

  # A request spec that builds its path from a mount point it computes
  # still names the endpoint by the rest of the path. An endpoint whose path
  # the source computes cannot be matched to a request, and the warning
  # says so instead of leaving it with no test.
  def test_a_grape_endpoint_path_built_at_run_time_is_named_in_a_warning
    api = lambda do |body|
      <<~RUBY
        class Books < Grape::API
          VERSION = "v1"
          namespace VERSION do
            post "books/:id/shelve" do
              #{body}
            end
            get "\#{Settings.legacy}/list" do
              #{body}
            end
          end
        end
      RUBY
    end
    with_repo do |repo|
      repo.write("app/api/books.rb", api.("1"))
      repo.write("spec/requests/books_spec.rb", %(RSpec.describe "Books" do\n  it "shelves" do\n    post "\#{api_root}/books/\#{book.id}/shelve"\n  end\nend\n))
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.write("app/api/books.rb", api.("2"))
      repo.commit("Answer 2.", date: "2026-02-12T00:00:00Z")

      change = JitCatch::Changes.between(repo.dir, "HEAD~1", "HEAD")
      assert_equal [["Books#GET /v1/{Settings.legacy}/list", []], ["Books#POST /v1/books/:id/shelve", [{ "file" => "spec/requests/books_spec.rb", "via" => "grep" }]]],
        change["methods"].map { |method| method.values_at("name", "existing_tests") }
      assert_equal ["Books#GET /v1/{Settings.legacy}/list (app/api/books.rb:7) builds its path from code jitcatch does not run, so no request a test sends is tied to it."],
        change["warnings"]
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

  def test_a_scope_is_a_class_method_and_a_delegate_an_instance_method
    with_repo do |repo|
      repo.write("app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n")
      post = <<~RUBY
        class Post < ApplicationRecord
          scope :recent, -> { where(created_at: 2.days.ago..) }
          scope :titled, ->(title) { where(title: title) }
          scope(:old) { where(created_at: ..2.years.ago) }
          scope :fresh, -> { recent.where(y: 2) }
          delegate :name, :email, to: :author, prefix: true
          delegate :plan, to: :account, private: true
        end
      RUBY
      repo.write("app/models/post.rb", post)
      repo.write("app/models/digest.rb", "class Digest\n  def self.build = Post.recent.to_a\nend\n")
      repo.write("spec/models/post_spec.rb", "RSpec.describe Post do\n  it \"lists recent\" do\n    expect(described_class.recent).to eq([])\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("app/models/post.rb", post.sub("2.days", "3.days").sub("where(title: title)", "where(title: title.strip)")
        .sub("2.years", "3.years").sub("->(title) {", "->(title, kind) {").sub(":name, :email, to: :author", ":name, :email, to: :writer").sub("to: :account", "to: :owner"))
      repo.commit("Widen recent.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [
        ["Post#author_email", "removed", "delegate :email, to: :author, prefix: true"],
        ["Post#author_name", "removed", "delegate :name, to: :author, prefix: true"],
        ["Post#plan", "modified", "delegate :plan, to: :owner, private: true"],
        ["Post#writer_email", "added", "delegate :email, to: :writer, prefix: true"],
        ["Post#writer_name", "added", "delegate :name, to: :writer, prefix: true"],
        ["Post.old", "modified", "scope(:old) { where(created_at: ..3.years.ago) }"],
        ["Post.recent", "modified", "scope :recent, -> { where(created_at: 3.days.ago..) }"],
        ["Post.titled", "modified", "scope :titled, ->(title, kind) { where(title: title.strip) }"]
      ], doc["methods"].map { |method| [method["name"], method["change"], method["new_source"] || method["old_source"]] }
      recent = doc["methods"].find { |method| method["name"] == "Post.recent" }
      assert_equal [["app/models/digest.rb", 2, "Digest.build"], ["app/models/post.rb", 5, "Post.fresh"]], recent["callsites"].map { |site| site.values_at("file", "line", "enclosing") }
      assert_equal ["changed"], doc["methods"].select { |method| method["name"] == "Post.titled" }.map { |method| method["signature"] }
      assert_equal ["private"], doc["methods"].select { |method| method["name"] == "Post#plan" }.map { |method| method["visibility"] }
      assert_includes doc["entrypoints"].find { |entry| entry["class"] == "Post" }["methods"].map { |method| method["name"] }, "Post.recent"
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
  def test_a_constant_that_gains_a_block_shows_the_block_open
    with_repo do |repo|
      repo.write("lib/line.rb", "Line = Struct.new(:cents)\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/line.rb", "Line = Struct.new(:cents) do\n  def total_cents = cents * 2\nend\n")
      repo.commit("Price a line.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")

      assert_equal [["modified", "Line = Struct.new(:cents)", "Line = Struct.new(:cents) do"]], doc["constants"].map { |const| const.values_at("change", "old_source", "new_source") }
    end
  end

  # A factory's class is read from its name, `class:`, `parent:`, or the
  # factory it nests in. One whose class the source does not settle is
  # left out and listed, so a reader knows which tests no line can name.
  def test_a_constructor_lists_the_tests_that_build_its_class
    with_repo do |repo|
      repo.write("lib/ledger.rb", "class Ledger\nend\n")
      factories = <<~RUBY
        FactoryBot.define do
          factory :loan do
            factory :approved_loan do
            end
          end
          factory :credit, class: "Loan"
          factory :debt, class: Loan, aliases: [:arrears]
          factory :overdue, parent: :loan
          factory :ledger
          factory :mystery, class: kind
          factory :api_key
          factory :orphan, parent: :nothing
          factory :api_record, class: Hash do
            skip_create
            initialize_with { {} }
          end
          factory :pair, class: "OpenStruct"
        end
      RUBY
      repo.write("spec/models/loan_spec.rb", "loan = create(:loan)\nexpect(loan.approved_by).to eq(\"nobody\")\n")
      repo.write("spec/models/desk_spec.rb", "Loan.create!(amount: 5)\n")
      repo.write("spec/models/new_spec.rb", "Loan.new\n")
      repo.write("spec/models/reflect_spec.rb", "Loan.instance_method(:initialize)\n")
      repo.write("spec/models/ledger_spec.rb", "create(:ledger)\n")
      repo.write("spec/models/own_spec.rb", "def create(name) = name\ncreate(:loan)\n")
      record_history(repo, factories: factories)

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      constructor = doc["methods"].find { |method| method["name"] == "Loan#initialize" }

      assert_equal [
        { "file" => "spec/models/desk_spec.rb", "via" => "builder", "calls" => ["Loan.create!"] },
        { "file" => "spec/models/loan_spec.rb", "via" => "builder", "calls" => ["create(:loan)"] },
        { "file" => "spec/models/new_spec.rb", "via" => "builder", "calls" => ["Loan.new"] }
      ], constructor["existing_tests"]
      assert_equal %w[Loan.build Loan.create Loan.create! build(:approved_loan) build(:arrears) build(:credit) build(:debt) build(:loan) build(:overdue) create(:approved_loan) create(:arrears) create(:credit) create(:debt) create(:loan) create(:overdue)],
        constructor["builders"]
      assert_equal [
        { "file" => "spec/factories/loans.rb", "line" => 10, "name" => "mystery", "reason" => "class: is not a constant, a string, or a symbol" },
        { "file" => "spec/factories/loans.rb", "line" => 11, "name" => "api_key", "reason" => "it builds ApiKey, which no file here defines" },
        { "file" => "spec/factories/loans.rb", "line" => 12, "name" => "orphan", "reason" => "its parent :nothing is not a factory read here" }
      ], doc["factories_skipped"]

      text = JitCatch::Render.context_text(doc)
      assert_includes text, "    tests: spec/models/desk_spec.rb via Loan.create!; spec/models/loan_spec.rb via create(:loan); spec/models/new_spec.rb via Loan.new\n"
      assert_includes text, "    built_by: Loan.build, Loan.create, Loan.create!, build(:approved_loan), build(:arrears), build(:credit), build(:debt), build(:loan), build(:overdue), create(:approved_loan), create(:arrears), create(:credit), create(:debt), create(:loan), create(:overdue)\n    tests: "
      assert_includes text, "factories_skipped:\n  spec/factories/loans.rb:10 factory :mystery: class: is not a constant, a string, or a symbol\n"
    end
  end

  # A removed callback is read from base, where its line still names it.
  def test_a_removed_callback_keeps_the_saves_that_ran_it
    with_repo do |repo|
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      repo.write("lib/loan.rb", "class Loan < ApplicationRecord\n  after_save :count_save\n\n  def count_save\n    1\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/loan.rb", "class Loan < ApplicationRecord\nend\n")
      repo.commit("Count no save.", date: "2026-02-12T00:00:00Z")

      removed = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].fetch(0)

      assert_equal ["Loan#count_save", "removed", ["after_save :count_save"], %w[Loan#save Loan#save! Loan#update Loan#update! Loan.create Loan.create!]],
        removed.values_at("name", "change", "callbacks", "run_by")
    end
  end

  # A test reaches a callback through the call ActiveRecord runs it from,
  # never by its name. The table of which call runs which declaration is
  # Rails's; a class outside ActiveRecord gets none.
  def test_a_callback_lists_the_tests_that_save_its_model
    with_repo do |repo|
      callback_history(repo)
      repo.write("spec/models/create_spec.rb", "Loan.create!(amount: 5)\n")
      repo.write("spec/models/factory_spec.rb", "create(:loan)\n")
      repo.write("spec/models/save_spec.rb", "loan = Loan.new\nloan.save!\n")
      repo.write("spec/models/destroy_spec.rb", "loan = Loan.new\nloan.destroy\n")
      repo.write("spec/models/valid_spec.rb", "loan = Loan.new\nloan.valid?\n")
      repo.write("spec/models/named_spec.rb", "Loan.new.count_save\n")
      repo.commit("specs", date: "2026-02-13T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      by_name = doc["methods"].to_h { |method| [method["name"], method] }

      saving = %w[Loan#save Loan#save! Loan#update Loan#update! Loan.create Loan.create! build(:loan) create(:loan)]
      assert_equal [["after_save :count_save"], saving], by_name["Loan#count_save"].values_at("callbacks", "run_by")
      assert_equal [["validates if: :checked?"], (saving + %w[Loan#invalid? Loan#valid? Loan#validate Loan#validate!]).sort],
        by_name["Loan#checked?"].values_at("callbacks", "run_by")
      assert_equal [["before_destroy :archive"], %w[Loan#destroy Loan#destroy!]], by_name["Loan#archived_mark"].values_at("callbacks", "run_by")
      assert_equal [[], []], by_name["Notes#tidy"].values_at("callbacks", "run_by")
      assert_equal [
        { "file" => "spec/models/create_spec.rb", "via" => "callback", "calls" => ["Loan.create!"] },
        { "file" => "spec/models/factory_spec.rb", "via" => "callback", "calls" => ["create(:loan)"] },
        { "file" => "spec/models/named_spec.rb", "via" => "grep" },
        { "file" => "spec/models/save_spec.rb", "via" => "callback", "calls" => ["Loan#save!"] }
      ], by_name["Loan#count_save"]["existing_tests"]
      assert_equal %w[spec/models/destroy_spec.rb], by_name["Loan#archived_mark"]["existing_tests"].map { |hit| hit["file"] }

      text = JitCatch::Render.context_text(doc)
      assert_includes text, "    run_by: #{saving.join(", ")} (after_save :count_save)\n    tests: spec/models/create_spec.rb via Loan.create!; "
    end
  end

  # A save the repository's own code makes runs the callback as a test's
  # save does, so the method that makes it, and that method's callers,
  # reach the callback. A local the source does not type, such as a
  # parameter, is read as the model Rails names it after (`loan` as Loan).
  def test_a_repository_method_that_saves_reaches_the_callback
    with_repo do |repo|
      callback_history(repo)
      repo.write("lib/loan_desk.rb", <<~RUBY)
        class LoanDesk
          def self.open(amount) = Loan.create!(amount: amount)

          def self.open_two = [open(1), open(2)]
        end
      RUBY
      repo.write("lib/teller.rb", "class Teller\n  def renew(loan)\n    loan.save!\n  end\n\n  def file(record) = record.save!\n\n  def close = Loan.new.destroy\nend\n")
      repo.write("lib/branch.rb", "class Branch\n  def renew_all(loans) = loans.each { |loan| Teller.new.renew(loan) }\nend\n")
      repo.commit("desk", date: "2026-02-13T00:00:00Z")

      by_name = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].to_h { |method| [method["name"], method] }

      assert_equal %w[Branch#renew_all LoanDesk.open LoanDesk.open_two Teller#renew], by_name["Loan#count_save"]["reachable_from"]
      assert_equal({ "Branch#renew_all" => 2, "LoanDesk.open" => 1, "LoanDesk.open_two" => 2, "Teller#renew" => 1 }, by_name["Loan#count_save"]["caller_depths"])
      assert_equal %w[Loan#archive Teller#close], by_name["Loan#archived_mark"]["reachable_from"]
    end
  end

  # `create(:loan)` saves the Borrower its `borrower` association builds,
  # so it runs Borrower's save callbacks.
  def test_a_factory_runs_the_callbacks_of_the_records_its_associations_build
    with_repo do |repo|
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      borrower = ->(name) { "class Borrower < ApplicationRecord\n  before_save :tidy\n\n  def tidy\n    #{name}\n  end\nend\n" }
      repo.write("lib/borrower.rb", borrower.call(":strip"))
      repo.write("lib/loan.rb", "class Loan < ApplicationRecord\n  belongs_to :borrower\nend\n")
      repo.write("spec/factories/lending.rb", "FactoryBot.define do\n  factory :borrower\n  factory :loan do\n    borrower\n  end\nend\n")
      repo.write("spec/models/loan_spec.rb", "create(:loan)\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/borrower.rb", borrower.call(":squish"))
      repo.commit("Squish the name.", date: "2026-02-12T00:00:00Z")

      tidy = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].fetch(0)

      assert_includes tidy["run_by"], "create(:loan)"
      assert_equal [{ "file" => "spec/models/loan_spec.rb", "via" => "callback", "calls" => ["create(:loan)"] }], tidy["existing_tests"]
    end
  end

# `create(:loan, :cosigned)` builds the Cosigner its trait names, and
# plain `create(:loan)` does not.
def test_a_trait_runs_the_callbacks_of_the_records_its_associations_build
  with_repo do |repo|
    repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
    cosigner = ->(name) { "class Cosigner < ApplicationRecord\n  before_save :tidy\n\n  def tidy\n    #{name}\n  end\nend\n" }
    repo.write("lib/cosigner.rb", cosigner.call(":strip"))
    repo.write("lib/loan.rb", "class Loan < ApplicationRecord\nend\n")
    repo.write("spec/factories/lending.rb", "FactoryBot.define do\n  factory :cosigner\n  factory :loan do\n    trait :cosigned do\n      cosigner\n    end\n  end\nend\n")
    repo.write("spec/models/cosigned_spec.rb", "create(:loan, :cosigned, amount: 5)\n")
    repo.write("spec/models/plain_spec.rb", "create(:loan)\n")
    repo.commit("base", date: "2026-02-11T00:00:00Z")
    repo.branch("base")
    repo.write("lib/cosigner.rb", cosigner.call(":squish"))
    repo.commit("Squish the name.", date: "2026-02-12T00:00:00Z")

    tidy = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].fetch(0)

    assert_includes tidy["run_by"], "create(:loan, :cosigned)"
    refute_includes tidy["run_by"], "create(:loan)"
    assert_equal [{ "file" => "spec/models/cosigned_spec.rb", "via" => "callback", "calls" => ["create(:loan, :cosigned)"] }], tidy["existing_tests"]
  end
end

# `on:` narrows a validation or commit callback to the saves of that
  # context: an update never runs a create-only callback, so a method that
  # only updates does not reach it. A custom context runs only from a call
  # that takes one.
  def test_a_callback_on_a_context_is_run_only_by_the_saves_of_that_context
    with_repo do |repo|
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      loan = lambda do |step|
        <<~RUBY
          class Loan < ApplicationRecord
            before_validation :mark_pending, on: :create
            validate :check_limit, on: :update
            after_commit :notify, on: [:create, :destroy]
            validates :amount, presence: true, if: :ready?, on: :publish
            before_save :tidy, on: :create

            def approve = update!(state: "approved")

            def mark_pending = #{step}
            def check_limit = #{step}
            def notify = #{step}
            def ready? = #{step}
            def tidy = #{step}
          end
        RUBY
      end
      repo.write("lib/loan.rb", loan.call(1))
      repo.write("lib/loan_desk.rb", "class LoanDesk\n  def self.open = Loan.create!(amount: 1)\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/loan.rb", loan.call(2))
      repo.commit("Step by two.", date: "2026-02-12T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      by_name = doc["methods"].to_h { |method| [method["name"], method] }

      validating = %w[Loan#invalid? Loan#valid? Loan#validate Loan#validate!]
      assert_equal [["before_validation :mark_pending, on: :create"], (%w[Loan#save Loan#save! Loan.create Loan.create!] + validating).sort, ["LoanDesk.open"]],
        by_name["Loan#mark_pending"].values_at("callbacks", "run_by", "reachable_from")
      assert_equal [["validate :check_limit, on: :update"], (%w[Loan#save Loan#save! Loan#update Loan#update!] + validating).sort, ["Loan#approve"]],
        by_name["Loan#check_limit"].values_at("callbacks", "run_by", "reachable_from")
      assert_equal [["after_commit :notify, on: [:create, :destroy]"], %w[Loan#destroy Loan#destroy! Loan#save Loan#save! Loan.create Loan.create!]],
        by_name["Loan#notify"].values_at("callbacks", "run_by")
      assert_equal [["validates if: :ready?, on: :publish"], (%w[Loan#save Loan#save!] + validating).sort, []],
        by_name["Loan#ready?"].values_at("callbacks", "run_by", "reachable_from")
      assert_equal %w[Loan#save Loan#save! Loan#update Loan#update! Loan.create Loan.create!], by_name["Loan#tidy"]["run_by"]
      assert_includes JitCatch::Render.context_text(doc), "    run_by: Loan#invalid?, Loan#save, Loan#save!, Loan#valid?, Loan#validate, Loan#validate!, Loan.create, Loan.create! (before_validation :mark_pending, on: :create)\n"
    end
  end

  # `build(:loan)` makes a record without saving it, so on its own it runs
  # no callback. A test that then saves or validates the record does run the
  # callbacks of a new record; RSpec's `be_valid` calls `valid?`.
  def test_a_built_record_runs_a_callback_only_when_the_test_saves_or_validates_it
    with_repo do |repo|
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      loan = lambda do |step|
        <<~RUBY
          class Loan < ApplicationRecord
            before_validation :mark_pending
            after_save :count_save
            after_update :log_update

            def mark_pending = #{step}
            def count_save = #{step}
            def log_update = #{step}
          end
        RUBY
      end
      repo.write("lib/loan.rb", loan.call(1))
      repo.write("spec/factories/loans.rb", "FactoryBot.define do\n  factory :loan\nend\n")
      repo.write("spec/models/build_spec.rb", "loan = build(:loan)\nexpect(loan.state).to eq(nil)\n")
      repo.write("spec/models/stub_spec.rb", "build_stubbed(:loan)\n")
      repo.write("spec/models/create_spec.rb", "create_list(:loan, 2)\n")
      repo.write("spec/models/valid_spec.rb", "expect(build(:loan)).to be_valid\n")
      repo.write("spec/models/save_spec.rb", "loan = build(:loan)\nloan.save!\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/loan.rb", loan.call(2))
      repo.commit("Step by two.", date: "2026-02-12T00:00:00Z")

      by_name = JitCatch::Changes.between(repo.dir, "base", "HEAD")["methods"].to_h { |method| [method["name"], method] }

      assert_includes by_name["Loan#count_save"]["run_by"], "build(:loan)"
      refute_includes by_name["Loan#log_update"]["run_by"], "build(:loan)"
      assert_equal %w[spec/models/create_spec.rb spec/models/save_spec.rb spec/models/valid_spec.rb], by_name["Loan#mark_pending"]["existing_tests"].map { |hit| hit["file"] }
      assert_equal [
        { "file" => "spec/models/create_spec.rb", "via" => "callback", "calls" => ["create(:loan)"] },
        { "file" => "spec/models/save_spec.rb", "via" => "callback", "calls" => ["build(:loan)"] }
      ], by_name["Loan#count_save"]["existing_tests"]
      assert_equal [], by_name["Loan#log_update"]["existing_tests"]
    end
  end
end
