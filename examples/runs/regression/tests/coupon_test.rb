# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# New behavior from the commit message. These describe SAVE5, so they
# are not expected to pass on the parent.
class CouponTest < Minitest::Test
  def test_save5_comes_off_before_tax
    cart = Shop::Cart.new.add("desk", 15_000, 1).apply_coupon("SAVE5")
    assert_equal 500, cart.coupon_discount_cents
    assert_equal 13_000, cart.taxable_cents
    assert_equal 1_040, cart.tax_cents
    assert_equal 14_040, cart.total_cents
  end

  def test_unknown_coupon_raises
    cart = Shop::Cart.new.add("pen", 1_000, 1)
    error = assert_raises(Shop::UnknownCoupon) { cart.apply_coupon("NOPE").coupon_discount_cents }
    assert_match(/NOPE/, error.message)
  end

  def test_save5_floors_taxable_at_zero
    cart = Shop::Cart.new.add("mint", 100, 1).apply_coupon("SAVE5")
    assert_equal 0, cart.taxable_cents
    assert_equal 0, cart.total_cents
  end
end
