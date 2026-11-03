# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# Tax rounding is not part of the SAVE5 intent. 12 cents * 8% = 0.96,
# which half-up sends to 1 and truncation would send to 0. 19 cents is
# the same kind of boundary (1.52 -> 2).
class RoundingTest < Minitest::Test
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
end
