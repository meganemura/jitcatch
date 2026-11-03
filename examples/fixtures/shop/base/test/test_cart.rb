# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/shop"

class TestCart < Minitest::Test
  def test_empty_total_is_zero
    assert_equal 0, Shop::Cart.new.total_cents
  end

  def test_subtotal_sums_lines
    cart = Shop::Cart.new
    cart.add("pen", 200, 3)
    cart.add("book", 1_500, 1)
    assert_equal 2_100, cart.subtotal_cents
  end

  def test_no_volume_discount_under_threshold
    cart = Shop::Cart.new.add("mug", 4_000, 1)
    assert_equal 0, cart.volume_discount_cents
    assert_equal 4_000, cart.taxable_cents
  end

  def test_volume_discount_above_threshold
    cart = Shop::Cart.new.add("desk", 15_000, 1)
    assert_equal 1_500, cart.volume_discount_cents
    assert_equal 13_500, cart.taxable_cents
    assert_equal 1_080, cart.tax_cents
    assert_equal 14_580, cart.total_cents
  end

  def test_tax_rounds_half_up
    cart = Shop::Cart.new.add("mint", 12, 1)
    assert_equal 0, cart.volume_discount_cents
    assert_equal 1, cart.tax_cents
    assert_equal 13, cart.total_cents
  end

  def test_rejects_non_positive_qty
    error = assert_raises(ArgumentError) { Shop::Cart.new.add("pen", 100, 0) }
    assert_match(/qty/, error.message)
  end
end
