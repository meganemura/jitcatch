# ケース: SAVE5 クーポン（回帰あり）

意図（`base..regression`）: SAVE5 は税引前に 500 セント引く。未知のコードは `Shop::UnknownCoupon`。閾値には触れていない。

## カウント

| 項目 | 数 |
| --- | ---: |
| generated | 13 |
| no_signal | 8 |
| fail_on_base | 3 |
| candidates | 2 |
| flaky | 0 |
| discarded | 0 |
| reported | 2 |

candidates は、base で通り head で落ち、再実行でも落ちたテスト。reported はそのうちルールで捨てなかったもの。

## 判断

- c02 `VolumeBoundaryTest#test_threshold_is_inclusive` — **likely-regression**。10000 セントちょうどで割引は 1000 であるべきところが 0。context の m05 は比較が `<` から `<=` に変わっている。メソッドのコメントは inclusive のまま。意図はクーポン追加だけなので、既存の境界を壊している。
- c01 `ThresholdTotalTest#test_at_threshold_total_includes_the_volume_discount` — **likely-regression**。同じ境界を、変更していない `total_cents` から見ている。期待 9720（割引後の税込み）、実際 10800（割引なし）。タグは `touches:unchanged_caller`、関連メソッドは m05。
- SAVE5 の 3 件は base で落ちた。`apply_coupon` が無く `NoMethodError` が 2 件、`Shop::UnknownCoupon` が無く `NameError` が 1 件。新機能のテストであり、候補にならない。回帰の証拠ではない。
- 9999 と 10001、15000 セントの合計、税の half-up、数量と価格のチェックは pass/pass。そこは壊れていない。
- unclear はない。

報告する回帰は 1 種類（閾値の off-by-one）で、テストは 2 件。ツールは「回帰」とは言わない。この仕分けは意図を読んだ結果。

既存の `test/test_cart.rb` は 4000 と 15000 しか見ていない。10000 ちょうどは元から穴だった。境界のテストを書かなければ、このバグは reported 0 のまま残る。
