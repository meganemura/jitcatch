# frozen_string_literal: true

require_relative "money"

module Shop
  class Cart
    VOLUME_THRESHOLD_CENTS = 10_000
    VOLUME_PERCENT = 10
    TAX_NUMERATOR = 8
    TAX_DENOMINATOR = 100

    def initialize
      @lines = []
    end

    def add(sku, unit_price_cents, qty)
      raise ArgumentError, "sku required" if sku.nil? || sku.to_s.empty?
      raise ArgumentError, "price must be >= 0" if unit_price_cents.negative?
      raise ArgumentError, "qty must be > 0" unless qty.is_a?(Integer) && qty.positive?

      @lines << { sku: sku.to_s, unit_price_cents: unit_price_cents, qty: qty }
      self
    end

    def subtotal_cents
      @lines.sum { |line| line[:unit_price_cents] * line[:qty] }
    end

    # 10% off once the subtotal reaches the threshold (inclusive).
    def volume_discount_cents
      return 0 if subtotal_cents < VOLUME_THRESHOLD_CENTS

      Money.percent(subtotal_cents, VOLUME_PERCENT)
    end

    def taxable_cents
      net = subtotal_cents - volume_discount_cents
      net.negative? ? 0 : net
    end

    def tax_cents
      Money.apply_rate(taxable_cents, TAX_NUMERATOR, TAX_DENOMINATOR)
    end

    def total_cents
      taxable_cents + tax_cents
    end
  end
end
