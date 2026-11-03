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
      assert_equal [["k01", "added", "New::LIMIT"], ["k02", "removed", "Old::LIMIT"]],
        doc["constants"].map { |const| const.values_at("id", "change", "name") }
      assert_equal [["Calc#add", "modified", "changed"], ["Old.gone", "removed", "removed"]],
        doc["methods"].map { |method| method.values_at("name", "change", "signature") }
      assert_equal [["A", "lib/new.rb"], ["D", "lib/old.rb"], ["M", "lib/calc.rb"]].sort_by(&:last),
        doc["files"].map { |file| file.values_at("status", "file") }
    end
  end
end
