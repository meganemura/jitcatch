# frozen_string_literal: true

module Shop
  # Integer-cent arithmetic. Rates use half-up rounding so a remainder of
  # exactly half a cent rounds away from zero.
  module Money
    module_function

    def percent(amount_cents, rate)
      raise ArgumentError, "amount must be >= 0" if amount_cents.negative?

      (amount_cents * rate + 50) / 100
    end

    def apply_rate(amount_cents, numerator, denominator)
      raise ArgumentError, "amount must be >= 0" if amount_cents.negative?

      (amount_cents * numerator + (denominator / 2)) / denominator
    end
  end
end
