# frozen_string_literal: true

require "minitest/autorun"
require "shop"

class UnchangedTest < Minitest::Test
  def test_twelve_cents_tax_rounds_half_up
    cart = Shop::Cart.new.add("mint", 12, 1)
    assert_equal 1, cart.tax_cents
    assert_equal 13, cart.total_cents
  end

  def test_nineteen_cents_tax_rounds_half_up
    cart = Shop::Cart.new.add("mint", 19, 1)
    assert_equal 2, cart.tax_cents
    assert_equal 21, cart.total_cents
  end

  def test_rejects_zero_qty
    assert_raises(ArgumentError) { Shop::Cart.new.add("pen", 100, 0) }
  end
end
