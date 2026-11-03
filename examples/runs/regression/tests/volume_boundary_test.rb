# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# m05 Shop::Cart#volume_discount_cents. The comment still says the
# threshold is inclusive. These tests state that rule.
class VolumeBoundaryTest < Minitest::Test
  def test_just_below_threshold_has_no_volume_discount
    cart = Shop::Cart.new.add("book", 9_999, 1)
    assert_equal 0, cart.volume_discount_cents
  end

  def test_threshold_is_inclusive
    cart = Shop::Cart.new.add("book", 10_000, 1)
    assert_equal 1_000, cart.volume_discount_cents
  end

  def test_just_above_threshold_keeps_volume_discount
    cart = Shop::Cart.new.add("book", 10_001, 1)
    assert_equal 1_000, cart.volume_discount_cents
  end
end
