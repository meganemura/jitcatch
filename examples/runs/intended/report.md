# Case: threshold lowered to 5000 cents (intended)

Intent (`base..intended`): lower the volume-discount threshold from 10000 to 5000 cents. Orders of 5000 cents or more get 10% off. The message says this is an intentional behavior change, and that tax rounding stays the same.

## Counts

| Item | Count |
| --- | ---: |
| generated | 9 |
| no_signal | 6 |
| fail_on_base | 1 |
| candidates | 2 |
| flaky | 0 |
| discarded | 0 |
| reported | 2 |

## Judgment

- c02 `ThresholdTest#test_five_thousand_had_no_discount` — **intended**. The test states the old rule (no discount at 5000). Head returns 500. In the context brief, k01 changes `10_000` to `5_000`, and m01 reads that constant. The intent asks for this change.
- c01 `ThresholdTest#test_between_old_and_new_threshold_total_had_no_discount` — **intended**. A 7500-cent total moves from 8100 to 7290. That is the 10% discount applying between 5000 and 10000, which the intent covers. Seen through unchanged `total_cents` (`touches:unchanged_caller`).
- `NewThresholdTest` states the new rule directly ("5000 receives the discount"). It fails on base, so it is not a candidate and not a regression.
- 4999, 10000, 15000, half-up tax, and quantity 0 are pass/pass.
- No likely-regression. Nothing is unclear.

The same pass-on-base / fail-on-head shape is a regression in case 1 and an intended change here. The difference is the commit message, which is why that judgment stays outside the tool.
