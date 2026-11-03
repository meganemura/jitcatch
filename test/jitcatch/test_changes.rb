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
end
