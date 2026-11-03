# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# Unchanged entry point Shop::Cart#total_cents. It reaches the changed
# discount through taxable_cents. No coupon is applied.
class ThresholdTotalTest < Minitest::Test
  def test_at_threshold_total_includes_the_volume_discount
    cart = Shop::Cart.new.add("book", 10_000, 1)
    assert_equal 9_720, cart.total_cents
  end

  def test_above_threshold_total_is_unchanged
    cart = Shop::Cart.new.add("desk", 15_000, 1)
    assert_equal 14_580, cart.total_cents
  end
end
