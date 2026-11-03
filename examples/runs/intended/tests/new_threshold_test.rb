# frozen_string_literal: true

require "minitest/autorun"
require "shop"

# States the new rule from the commit message. The parent does not do this.
class NewThresholdTest < Minitest::Test
  def test_five_thousand_receives_volume_discount
    cart = Shop::Cart.new.add("mug", 5_000, 1)
    assert_equal 500, cart.volume_discount_cents
  end
end
