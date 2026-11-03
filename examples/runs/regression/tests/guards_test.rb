# frozen_string_literal: true

require "minitest/autorun"
require "shop"

class GuardsTest < Minitest::Test
  def test_rejects_zero_qty
    assert_raises(ArgumentError) { Shop::Cart.new.add("pen", 100, 0) }
  end

  def test_rejects_blank_sku
    assert_raises(ArgumentError) { Shop::Cart.new.add("", 100, 1) }
  end

  def test_rejects_negative_price
    assert_raises(ArgumentError) { Shop::Cart.new.add("pen", -1, 1) }
  end
end
