# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# m01 reads VOLUME_THRESHOLD_CENTS. The old rule was "discount at 10000".
class ThresholdTest < Minitest::Test
  def test_below_five_thousand_has_no_discount
    cart = Shop::Cart.new.add("mug", 4_999, 1)
    assert_equal 0, cart.volume_discount_cents
  end

  def test_five_thousand_had_no_discount
    cart = Shop::Cart.new.add("mug", 5_000, 1)
    assert_equal 0, cart.volume_discount_cents
  end

  def test_between_old_and_new_threshold_total_had_no_discount
    cart = Shop::Cart.new.add("mug", 7_500, 1)
    assert_equal 8_100, cart.total_cents
  end

  def test_ten_thousand_still_receives_the_discount
    cart = Shop::Cart.new.add("desk", 10_000, 1)
    assert_equal 1_000, cart.volume_discount_cents
  end

  def test_above_old_threshold_total_is_unchanged
    cart = Shop::Cart.new.add("desk", 15_000, 1)
    assert_equal 14_580, cart.total_cents
  end
end
