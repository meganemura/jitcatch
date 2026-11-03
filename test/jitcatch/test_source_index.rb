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
    assert_equal [["Shop", "", "module Shop"], ["Shop::Cart", "Shop", "class Cart"]],
      index.namespaces.map { |const| [const.qualified, const.qualifier, const.source] }

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

  def test_private_class_method_and_private_names_inside_class_of_self
    source = <<~RUBY
      module Quint
        def self.capture(cmd)
          cmd
        end
        private_class_method :capture

        private_class_method def self.spawn(cmd)
          cmd
        end

        def self.run(cmd)
          capture(cmd)
        end

        def capture(cmd)
          cmd
        end

        class << self
          def reset
            1
          end
          private :reset
        end

        def self.later
          2
        end
        private_class_method :later, :run
        public_class_method :run
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/quint.rb")
    visibility = index.methods.to_h { |method| [method.qualified, method.visibility] }
    assert_equal({
      "Quint.capture" => "private", "Quint.spawn" => "private", "Quint.run" => "public",
      "Quint#capture" => "public", "Quint.reset" => "private", "Quint.later" => "private"
    }, visibility)
  end

  def test_module_function_makes_a_public_module_method
    source = <<~RUBY
      module Text
        def plain
          1
        end

        module_function

        def mask(text)
          clean(text)
        end

        private

        def hidden
          2
        end
      end

      module Util
        def two
          2
        end

        def one
          two
        end
        module_function :one
      end

      module Other
        def one
          1
        end
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/text.rb")
    assert_equal({ "Text#plain" => "public", "Text.mask" => "public", "Text#hidden" => "private",
                   "Util.one" => "public", "Util#two" => "public", "Other#one" => "public" },
      index.methods.to_h { |method| [method.qualified, method.visibility] })
    assert_equal "singleton", index.methods.find { |method| method.qualified == "Text.mask" }.kind
    assert_equal "Text.mask", index.calls.find { |call| call.bare_name == "clean" }.enclosing
    assert_equal "Util.one", index.calls.find { |call| call.bare_name == "two" }.enclosing
  end

  def test_methods_under_a_private_constant_are_private
    source = <<~RUBY
      module A
        module B
          def self.x = 1

          class Deep
            def y = 2
          end
        end
        private_constant :B

        Impl = Class.new do
          def z = 3
        end
        self.private_constant "Impl"

        module Open
          def self.w = 4
        end

        module Bee
          def self.v = 5
        end
        Other.private_constant :Bee
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/a.rb")
    assert_equal({ "A::B.x" => "private", "A::B::Deep#y" => "private", "A::Impl#z" => "private",
                   "A::Open.w" => "public", "A::Bee.v" => "public" },
      index.methods.to_h { |method| [method.qualified, method.visibility] })
  end

  def test_methods_in_a_block_given_to_a_constant_belong_to_that_constant
    source = <<~RUBY
      module Geo
        Point = Struct.new(:x, :y) do
          def norm
            Math.sqrt(x * x + y * y)
          end
        end

        Geo::Line = Class.new(Base) do
          def self.build
            norm
          end
        end

        LIMIT = 3
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/geo.rb")
    assert_equal [["Geo::Line.build", "Geo::Line", 9], ["Geo::Point#norm", "Geo::Point", 3]],
      index.methods.map { |method| [method.qualified, method.qualifier, method.start_line] }.sort
    assert_equal [["Geo::LIMIT", "LIMIT = 3", 14, 14], ["Geo::Line", "Geo::Line = Class.new(Base)", 8, 8], ["Geo::Point", "Point = Struct.new(:x, :y)", 2, 2]],
      index.constants.map { |const| [const.qualified, const.source, const.start_line, const.end_line] }.sort
    assert_equal "Geo::Line.build", index.calls.find { |call| call.bare_name == "norm" }.enclosing
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
  def test_referenced_names_read_code_through_helpers_and_skip_strings_and_comments
    source = <<~'RUBY'
      module Util
        module_function

        def build(n) = Shop::Cart.new(n)
      end

      class CartTest
        def test_total
          # apply_coupon is not called here
          cart = Util.build("apply_coupon")
          cart.total ||= 1
          cart.items, = [], 1
          assert_equal "x #{cart.size}", cart.public_send(:label)
        end

        def test_other
          other_only
        end
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "test/cart_test.rb")

    assert_equal %w[Cart Cart.new Shop Util assert_equal build items= label new public_send size total total=],
      index.referenced_names("CartTest#test_total")
    assert_equal %w[Cart Cart.new Shop new], index.referenced_names("Util.build")
    assert_equal %w[Cart Cart.new CartTest Shop Util assert_equal build items= label module_function new other_only public_send size total total=],
      index.referenced_names("CartTest#test_missing")
  end
end
