# frozen_string_literal: true

require_relative "../test_helper"

class TestSourceIndex < Minitest::Test
  def test_methods_constants_visibility_and_calls
    source = <<~RUBY
      module Shop
        class Cart
          LIMIT = 10

          def add(sku, qty)
            total(sku)
          end

          def self.build
            new
          end

          private

          def hidden(a, b = 1)
            a
          end

          def self.still_public
            1
          end

          class << self
            def from_hash(h)
              h
            end

            private

            def secret
              1
            end
          end
        end

        private def helper(x)
          x
        end
      end

      def top(a)
        a
      end
    RUBY

    index = JitCatch::SourceIndex.parse(source, file: "lib/cart.rb")
    refute index.parse_error
    by_name = index.methods.to_h { |method| [method.qualified, method] }

    assert_equal "public", by_name["Shop::Cart#add"].visibility
    assert_equal "sku,qty", by_name["Shop::Cart#add"].params
    assert_equal "instance", by_name["Shop::Cart#add"].kind
    assert_equal "public", by_name["Shop::Cart.build"].visibility
    assert_equal "singleton", by_name["Shop::Cart.build"].kind
    assert_equal "private", by_name["Shop::Cart#hidden"].visibility
    assert_equal "public", by_name["Shop::Cart.still_public"].visibility
    assert_equal "public", by_name["Shop::Cart.from_hash"].visibility
    assert_equal "private", by_name["Shop::Cart.secret"].visibility
    assert_equal "private", by_name["Shop#helper"].visibility
    assert_equal "public", by_name["#top"].visibility

    limit = index.constants.find { |const| const.bare_name == "LIMIT" }
    assert_equal "Shop::Cart::LIMIT", limit.qualified
    assert_equal "LIMIT = 10", limit.source

    call = index.calls.find { |item| item.bare_name == "total" }
    assert_equal "Shop::Cart#add", call.enclosing
    assert_operator call.line, :>, 0
  end

  def test_calls_name_the_enclosing_method_in_each_singleton_context
    source = <<~RUBY
      module Shop
        def helper
          log
        end

        class Cart
          attr_reader :items

          def self.build
            make
          end

          class << self
            def from_hash(h)
              load_hash
            end
          end

          track_changes

          def add(sku)
            total
          end
        end
      end

      def top
        boot
      end

      configure
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib\\shop.rb")
    enclosing = index.calls.to_h { |call| [call.bare_name, call.enclosing] }
    assert_equal "Shop#helper", enclosing["log"]
    assert_equal "Shop::Cart.build", enclosing["make"]
    assert_equal "Shop::Cart.from_hash", enclosing["load_hash"]
    assert_equal "Shop::Cart#add", enclosing["total"]
    assert_equal "#top", enclosing["boot"]
    assert enclosing.key?("configure")
    assert_nil enclosing["configure"]

    add = index.methods.find { |method| method.qualified == "Shop::Cart#add" }
    assert_equal ["lib/shop.rb", "public", "    def add(sku)\n      total\n    end"], [add.file, add.visibility, add.source]
  end

  def test_split_qualified_reverses_qualify
    assert_equal "Calc#add", JitCatch::SourceIndex.qualify("Calc", "add", false)
    assert_equal "Shop::Cart.build", JitCatch::SourceIndex.qualify("Shop::Cart", "build", true)
    assert_equal "#top", JitCatch::SourceIndex.qualify("", "top", false)
    assert_equal ["Calc", "#", "add"], JitCatch::SourceIndex.split_qualified("Calc#add")
    assert_equal ["Shop::Cart", ".", "build"], JitCatch::SourceIndex.split_qualified("Shop::Cart.build")
    assert_equal ["", "#", "top"], JitCatch::SourceIndex.split_qualified("#top")
    assert_equal ["", "#", "label"], JitCatch::SourceIndex.split_qualified("label")
  end

  def test_parse_error_is_recorded
    index = JitCatch::SourceIndex.parse("def (\n", file: "lib/bad.rb")
    assert index.parse_error
    assert_match(/L1:/, index.parse_error)
    assert_empty index.methods
  end
end
