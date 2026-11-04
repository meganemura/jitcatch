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

  # A test may hold a byte string that is not valid UTF-8; it names no path.
  def test_a_string_of_invalid_bytes_is_not_a_path
    source = "class T\n  def test_bytes\n    run(\"bin/x\", \"\\xFF/\\xFE\")\n  end\nend\n"
    index = JitCatch::SourceIndex.parse(source, file: "test/t.rb")

    assert_equal ["bin/x"], index.paths_named("T#test_bytes", nil)
  end

  # A test reaches the paths its own body and its helpers write. A name the
  # file does not define, such as a file-level row, reaches every path.
  def test_paths_named_reads_the_paths_a_test_reaches
    source = "class T\n  def test_a\n    run(\"bin/a\")\n  end\n\n  def test_b\n    helper\n  end\n\n  def helper\n    run(\"bin/b\")\n  end\nend\n"
    index = JitCatch::SourceIndex.parse(source, file: "test/t.rb")

    assert_equal ["bin/a"], index.paths_named("T#test_a", nil)
    assert_equal ["bin/b"], index.paths_named("T#test_b", nil)
    assert_equal ["bin/a", "bin/b"], index.paths_named("T#load", nil)
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
    assert_equal [["Geo::Line.build", "Geo::Line", 9], ["Geo::Point#norm", "Geo::Point", 3], ["Geo::Point#x", "Geo::Point", 2], ["Geo::Point#x=", "Geo::Point", 2], ["Geo::Point#y", "Geo::Point", 2], ["Geo::Point#y=", "Geo::Point", 2]],
      index.methods.map { |method| [method.qualified, method.qualifier, method.start_line] }.sort
    assert_equal [["Geo::LIMIT", "LIMIT = 3", 14, 14], ["Geo::Line", "Geo::Line = Class.new(Base) do", 8, 8], ["Geo::Point", "Point = Struct.new(:x, :y) do", 2, 2]],
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

        def build(n) = n.zero? ? Shop::Cart.new(n) : build(n - 1)
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

    assert_equal %w[- Cart Shop Shop::Cart.new Util Util.build assert_equal build items= label new public_send size total total= zero?],
      index.referenced_names("CartTest#test_total")
    assert_equal %w[- Cart Shop Shop::Cart.new build new zero?], index.referenced_names("Util.build")
    assert_equal %w[- Cart CartTest Shop Shop::Cart.new Util Util.build assert_equal build items= label module_function new other_only public_send size total total= zero?],
      index.referenced_names("CartTest#test_missing")
  end
  # A FactoryBot call names its factory as `create(:loan)` when it saves
  # the record and `build(:loan)` when it does not. One the file defines
  # itself, an argument that is not a symbol, and `attributes_for`, which
  # builds no object, name none.
  def test_a_factory_call_names_its_factory
    source = <<~'RUBY'
      RSpec.describe Loan do
        let(:loan) { create(:loan, :approved) }

        it("lists") { FactoryBot.build_list("ledger", 2) && build_stubbed(:debt) }
        it("names") { create(kind) && attributes_for(:credit) && Other.create(:credit) && Other::Deep.create(:other) }
      end
    RUBY
    own = <<~'RUBY'
      class OwnTest
        def test_own = create(:loan)
        def create(name) = name
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "spec/loan_spec.rb")

    assert_equal ["build(:debt)", "build(:ledger)", "create(:loan)", "create(:loan, :approved)"], index.example_references(4).grep(/\A(?:build|create)\(/)
    assert_equal ["create(:loan)", "create(:loan, :approved)"], index.example_references(5).grep(/\A(?:build|create)\(/)
    assert_equal [], JitCatch::SourceIndex.parse(own, file: "test/own_test.rb").referenced_names("OwnTest#test_own").grep(/\A(?:build|create)\(/)
    assert_includes JitCatch::SourceIndex.parse("create(:loan)\n", file: "spec/top_spec.rb").referenced_names(""), "create(:loan)"
  end

# Every require_relative counts, in a method or a block too. A path the
# source does not settle comes back as nil, so the run can say it could
# not check that line; a call of another name, or one with two paths,
# loads nothing to compare.
def test_relative_requires_are_every_require_relative_with_its_path
  source = <<~'SOURCE'
    require "minitest/autorun"
    require_relative "../lib/a"
    load_fixture "../fixtures/b"
    require_relative File.join("..", "lib", "c")
    require_relative "d", "e"
    require_relative File.join(__dir__, "f")

    class ATest
      require_relative "helper"

      def setup = require_relative("../lib/g")
    end

    RSpec.describe "A" do
      before { require_relative "support/#{kind}" }
    end
  SOURCE

  found = JitCatch::SourceIndex.relative_requires(source).map(&:to_h)

  assert_equal [
    { path: "../lib/a", line: 2 }, { path: "../lib/c", line: 4 }, { path: nil, line: 6 },
    { path: "helper", line: 9 }, { path: "../lib/g", line: 11 }, { path: nil, line: 15 }
  ], found
end

  def test_names_sent_only_to_constants_follow_the_scope_of_the_mentions
    source = <<~'RUBY'
      class WriteTest
        def test_file = File.write(path, 1) && Cart.new.total
        def test_writer = writer.write(1) && File.write(path, 1)
      end

      RSpec.describe Cart do
        it("reads") { Dir.mktmpdir }
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "test/write_test.rb")

    assert_equal({ "new" => ["Cart"], "write" => ["File"] }, index.names_sent_only_to_constants("WriteTest#test_file", nil))
    assert_equal({}, index.names_sent_only_to_constants("WriteTest#test_writer", nil))
    assert_equal({ "mktmpdir" => ["Dir"] }, index.names_sent_only_to_constants("", 7))
    assert_equal({ "mktmpdir" => ["Dir"], "new" => ["Cart"] }, index.names_sent_only_to_constants("WriteTest#test_missing", nil))
  end

  # `send(:write)` sends `write` to a receiver that is not the constant, so
  # `File.write` in the same test does not make `write` foreign.
  def test_a_name_sent_by_send_is_not_sent_only_to_constants
    source = <<~'RUBY'
      class WriteTest
        def test_send = File.write(path, 1) && emitter.send(:write) && Cart.public_send("total")
        def test_self = send(:write) && File.write(path, 1)
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "test/write_test.rb")

    assert_equal({ "total" => ["Cart"] }, index.names_sent_only_to_constants("WriteTest#test_send", nil).except("send", "public_send"))
    assert_equal({}, index.names_sent_only_to_constants("WriteTest#test_self", nil))
  end

  def test_a_hash_key_symbol_is_not_a_mention_and_a_reflective_call_is
    source = <<~'RUBY'
      class SnapTest
        def test_snap
          snap = cart.snapshot
          assert_equal 1, snap[:discount_cents]
          snap[:tax_cents] = snap.fetch(:subtotal_cents) + snap.dig(:lines, :qty_cents)
          snap.key?(:coupon_cents)
          row = { label: price_of(1), :sku => sku_of(2), key_of(3) => 4 }
          Order.new(qty: 3)
          cart.send(:priv_sym)
          cart.method(:meth_sym)
          cart.respond_to?(:resp_sym)
          cart.send("priv_str")
          cart.public_send("pub_str", 1)
          cart.method("meth_str")
          cart.send("interp_#{row}")
        end
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "test/snap_test.rb")

    assert_equal %w[+ Order Order.new [] []= assert_equal cart dig fetch key? key_of meth_str meth_sym method new price_of priv_str priv_sym pub_str public_send resp_sym respond_to? send sku_of snapshot],
      index.referenced_names("SnapTest#test_snap")
  end
end

class TestSourceIndexExamples < Minitest::Test
  SPEC = <<~RUBY
    require "spec_helper"

    RSpec.describe Cart do
      subject(:cart) { described_class.new(prices) }

      let(:prices) { [1] }

      def doubled(value) = twice(value)

      def twice(value) = value * 2

      describe "#total" do
        before { prices << subtotal }

        it "sums" do
          expect(cart.total).to eq(doubled(1))
        end
      end

      context "when empty" do
        let(:prices) { [] }

        it("labels") { expect(cart.label).to eq("cart") }
      end

      it "is plain" do
        expect(1 + 1).to eq(2)
      end
    end

    describe Other do
      it("stands apart") { Other.build }
    end
  RUBY

  def index
    JitCatch::SourceIndex.parse(SPEC, file: "cart_spec.rb")
  end

  def test_an_example_reads_its_block_its_groups_setup_and_helpers
    assert_equal %w[* << Cart Cart#total Cart.new described_class doubled eq expect new subtotal to total twice], index.example_references(15)
  end

  def test_a_sibling_group_setup_and_a_neighbor_are_not_read
    assert_equal %w[Cart Cart#label Cart.new described_class eq expect label new to], index.example_references(23)
    refute_includes index.example_references(26), "label"
  end

  def test_a_group_described_as_a_method_names_it
    index = JitCatch::SourceIndex.parse(%(describe "#total" do\n  it("works") { expect(1).to eq(1) }\nend\n), file: "t_spec.rb")
    assert_includes index.example_references(2), "total"
  end

  def test_only_described_class_new_names_the_described_constant
    source = %(describe Cart do\n  it("a") { factory.new }\n  it("b") { x.described_class.new }\n  it("c") { described_class.new }\nend\n)
    index = JitCatch::SourceIndex.parse(source, file: "c_spec.rb")
    refute_includes index.example_references(2), "Cart.new"
    refute_includes index.example_references(3), "Cart.new"
    assert_includes index.example_references(4), "Cart.new"
  end

  def test_a_describe_sent_to_another_constant_is_not_a_group
    index = JitCatch::SourceIndex.parse(%(Shop.describe(Cart) do\n  it("b") { 1 }\nend\n), file: "c_spec.rb")
    assert_equal [], index.example_references(2)
  end

  def test_a_top_level_describe_without_rspec_is_a_group_too
    assert_equal %w[Other Other.build build], index.example_references(32)
  end

  def test_a_named_receiver_names_its_class_and_a_let_names_no_method
    source = <<~SPEC
      RSpec.describe Index do
        subject(:result) { described_class.parse("x") }

        it("parses") { expect(result).to eq(Index.new.size) }
      end

      describe "free" do
        it("asks the class") { described_class.parse("x") }
      end
    SPEC
    index = JitCatch::SourceIndex.parse(source, file: "index_spec.rb")

    assert_equal %w[Index Index#size Index.new Index.parse described_class eq expect new parse size to], index.example_references(4)
    refute_includes index.example_references(8), "Index.parse"
  end

  def test_a_let_or_subject_that_builds_one_class_types_its_calls
    source = <<~SPEC
      RSpec.describe Cart do
        it("totals") { expect(cart.total + subject.size + either.label + kept.name + box.cart.weight).to eq(1) }

        let(:cart) { Cart.new }
        subject { described_class.new }
        let(:either) { flag ? Cart.new : Order.new }
        let(:kept) { Cart.new if Order.new }
      end
    SPEC
    names = JitCatch::SourceIndex.parse(source, file: "cart_spec.rb").example_references(2)

    assert_equal %w[Cart#name Cart#size Cart#total], names.grep(/#/)
  end

  def test_only_a_let_or_subject_symbol_names_a_spec_helper
    source = <<~SPEC
      RSpec.describe Cart do
        subject { described_class.new }

        it("totals") { expect(subject).to respond_to(:total) }
      end
    SPEC
    index = JitCatch::SourceIndex.parse(source, file: "cart_spec.rb")

    assert_includes index.example_references(4), "total"
  end

  def test_a_line_with_no_example_reads_nothing
    assert_nil index.example_references(3)
    assert_nil index.example_references(13)
  end

  def test_a_plain_block_call_is_not_an_example
    other = JitCatch::SourceIndex.parse("items.each { |item| it(item) }\n[1].map do |x| it x end\n", file: "x_spec.rb")
    assert_nil other.example_references(1)
    assert_nil other.example_references(2)
  end

  def test_attribute_macros_and_member_lists_define_methods_with_their_visibility
    source = <<~RUBY
      class Mismatch < StandardError
        attr_reader :trace, :seed
        attr_accessor :note
        private attr_writer :hidden
        private delegate_to :hidden

        class << self
          attr_reader :count
        end

        private

        attr_reader :secret
      end

      class Pair < Struct.new(:left)
      end

      Pick = Data.define(:name)
      Plain = Builder.new(:name)
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/mismatch.rb")
    assert_equal [
      ["Mismatch#hidden=", "private", "attr_writer :hidden", "value", 4],
      ["Mismatch#note", "public", "attr_reader :note", "", 3],
      ["Mismatch#note=", "public", "attr_writer :note", "value", 3],
      ["Mismatch#secret", "private", "attr_reader :secret", "", 13],
      ["Mismatch#seed", "public", "attr_reader :seed", "", 2],
      ["Mismatch#trace", "public", "attr_reader :trace", "", 2],
      ["Mismatch.count", "public", "attr_reader :count", "", 8],
      ["Pair#left", "public", "Struct.new(:left)", "", 16],
      ["Pair#left=", "public", "Struct.new(:left)", "value", 16],
      ["Pick#name", "public", "Data.define(:name)", "", 19]
    ], index.methods.map { |method| [method.qualified, method.visibility, method.source, method.params, method.start_line] }.sort
  end

  def test_a_splat_of_a_symbol_list_constant_defines_its_members
    source = <<~RUBY
      module Geo
        FIELDS = %i[x y].freeze
        NAMES = [:label]
        WORDS = %w[a b]

        Point = Struct.new(*FIELDS)
        Tag = Data.define(*NAMES, :kind)

        class Box
          attr_reader(*FIELDS)
          attr_reader(*UNKNOWN)
          attr_reader(*WORDS)
        end
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/geo.rb")

    assert_equal [
      ["Geo::Box#x", "attr_reader :x", 2],
      ["Geo::Box#y", "attr_reader :y", 2],
      ["Geo::Point#x", "Struct.new(:x)", 2],
      ["Geo::Point#x=", "Struct.new(:x)", 2],
      ["Geo::Point#y", "Struct.new(:y)", 2],
      ["Geo::Point#y=", "Struct.new(:y)", 2],
      ["Geo::Tag#kind", "Data.define(:kind)", 7],
      ["Geo::Tag#label", "Data.define(:label)", 3]
    ], index.methods.map { |method| [method.qualified, method.source, method.start_line] }.sort
  end

  def test_a_bare_private_in_a_conditional_carries_past_it
    source = <<~RUBY
      class Order
        def open = 1

        if defined?(Money)
          private

          def cents = 1
        end

        def secret = 2

        unless ENV["LEGACY"]
          public
        else
          def legacy = 3
        end

        def total = 4
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/order.rb")
    assert_equal [
      ["Order#cents", "private"],
      ["Order#legacy", "public"],
      ["Order#open", "public"],
      ["Order#secret", "private"],
      ["Order#total", "public"]
    ], index.methods.map { |method| [method.qualified, method.visibility] }.sort
  end

  def test_a_conditional_or_a_concern_block_defines_what_it_holds
    source = <<~RUBY
      class Order
        attr_reader :total if defined?(Money)

        unless ENV["LEGACY"]
          attr_accessor :note
        else
          def note = "legacy"
        end

        private

        if true
          attr_reader :secret
        end
      end

      module Billable
        extend ActiveSupport::Concern

        included do
          attr_reader :invoice
          def bill = invoice
        end

        class_methods do
          def billing = :monthly
        end

        def before = included
      end
    RUBY
    index = JitCatch::SourceIndex.parse(source, file: "lib/order.rb")
    assert_equal [
      ["Billable#before", "public", 29],
      ["Billable#bill", "public", 22],
      ["Billable#invoice", "public", 21],
      ["Billable.billing", "public", 26],
      ["Order#note", "public", 5],
      ["Order#note", "public", 7],
      ["Order#note=", "public", 5],
      ["Order#secret", "private", 13],
      ["Order#total", "public", 2]
    ], index.methods.map { |method| [method.qualified, method.visibility, method.start_line] }.sort
  end

  # Only a symbol names a method: a string, a lambda, or a block runs code
  # the line does not name. `validates` names attributes, and an option
  # other than `if:` and `unless:` names no method. `on:` is kept with the
  # line. A line sent to another
  # receiver, or to the singleton class, declares nothing for the class.
  def test_a_callback_or_validation_line_names_the_methods_it_runs
    source = <<~RUBY
      class Loan < ApplicationRecord
        self.before_save :stamp
        Other.after_save :elsewhere
        delegate :total, to: :ledger
        validates :amount, presence: true, if: :checked?, unless: [:closed?, :frozen?], on: :create
        validate :limit, if: -> { true }
        before_save "noted", -> { 1 }
        after_commit :notify, :log

        class << self
          after_save :count
        end
      end
    RUBY

    index = JitCatch::SourceIndex.parse(source, file: "app/models/loan.rb")

    assert_equal [
      ["Loan", "before_save", "stamp", "before_save :stamp"],
      ["Loan", "validates", "checked?", "validates if: :checked?, on: :create"],
      ["Loan", "validates", "closed?", "validates unless: :closed?, on: :create"],
      ["Loan", "validates", "frozen?", "validates unless: :frozen?, on: :create"],
      ["Loan", "validate", "limit", "validate :limit"],
      ["Loan", "after_commit", "notify", "after_commit :notify"],
      ["Loan", "after_commit", "log", "after_commit :log"]
    ], index.callbacks.map { |callback| callback.to_h.values_at(:qualifier, :macro, :method, :declared) }
  end

  # An `on:` that names no context as a symbol could be any context, so it
  # narrows nothing and the line does not show it.
  def test_an_on_that_names_no_symbol_narrows_nothing
    source = <<~RUBY
      class Loan < ApplicationRecord
        validate :named, on: KINDS
        validate :listed, on: [:create, kind]
        validate :empty, on: []
        validate :created, on: :create
      end
    RUBY

    callbacks = JitCatch::SourceIndex.parse(source, file: "app/models/loan.rb").callbacks

    all = JitCatch::SourceIndex::RECORD_CALLBACKS.fetch(:validate)
    assert_equal [[nil, "validate :named", all], [nil, "validate :listed", all], [nil, "validate :empty", all]],
      callbacks.first(3).map { |callback| [callback.contexts, callback.declared, callback.calls] }
    assert_equal [["create"], %w[#invalid? #save #save! #valid? #validate #validate! .create .create!]], [callbacks.last.contexts, callbacks.last.calls.sort]
  end
end
