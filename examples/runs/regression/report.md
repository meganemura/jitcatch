# Case: SAVE5 coupon, with a regression

Intent (`base..regression`): SAVE5 takes 500 cents off before tax. Unknown codes raise `Shop::UnknownCoupon`. The message does not mention the volume-discount threshold.

## Counts

| Item | Count |
| --- | ---: |
| generated | 13 |
| no_signal | 8 |
| fail_on_base | 3 |
| candidates | 2 |
| flaky | 0 |
| discarded | 0 |
| reported | 2 |

`candidates` passed on base, failed on head, and failed the same way on the reruns. `reported` is what remained after the rules.

## Judgment

- c02 `VolumeBoundaryTest#test_threshold_is_inclusive` — **likely-regression**. At exactly 10000 cents the discount should be 1000. Head returns 0. In the context brief, m05 changes `<` to `<=`. The method comment still says the threshold is inclusive. The intent only adds a coupon, so this breaks existing behavior.
- c01 `ThresholdTotalTest#test_at_threshold_total_includes_the_volume_discount` — **likely-regression**. The same boundary, seen through unchanged `total_cents`. Expected 9720 (tax after the discount), actual 10800 (no discount). Tag `touches:unchanged_caller`, related method m05.
- The three SAVE5 tests fail on base: two `NoMethodError`s because `apply_coupon` does not exist, and one `NameError` because `Shop::UnknownCoupon` does not exist. They describe the new feature and are not candidates. They are not evidence of a regression.
- 9999, 10001, the 15000-cent total, half-up tax, and the price and quantity checks are pass/pass. Those paths are intact.
- Nothing is unclear.

The report is two tests and one regression (an off-by-one on the threshold). The tool does not say "regression". That label comes from reading the intent.

The existing `test/test_cart.rb` only covers 4000 and 15000 cents. Exactly 10000 was already a gap. Without a boundary test, this bug stays at reported 0.
