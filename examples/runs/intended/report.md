# ケース: 閾値を 5000 セントへ（意図した変更）

意図（`base..intended`）: ボリューム割引の閾値を 10000 から 5000 セントへ下げる。5000 以上は 10% 引き。意図した振る舞いの変更であり、税の丸めは変えない。

## カウント

| 項目 | 数 |
| --- | ---: |
| generated | 9 |
| no_signal | 6 |
| fail_on_base | 1 |
| candidates | 2 |
| flaky | 0 |
| discarded | 0 |
| reported | 2 |

## 判断

- c02 `ThresholdTest#test_five_thousand_had_no_discount` — **intended**。古い規則（5000 では割引なし）を書いたテスト。head では 500。context の k01 が `10_000` から `5_000` になり、m01 がその定数を読んでいる。意図がその変更を明記している。
- c01 `ThresholdTest#test_between_old_and_new_threshold_total_had_no_discount` — **intended**。7500 セントの合計が 8100 から 7290 になった。5000 と 10000 の間に 10% が付いたということで、意図の範囲。変更していない `total_cents` 経由（`touches:unchanged_caller`）。
- `NewThresholdTest` は「5000 で割引がある」という新しい規則を直接書いている。base では失敗するので候補にならない。回帰ではない。
- 4999、10000、15000、税の half-up、数量 0 は pass/pass。
- likely-regression はない。unclear もない。

同じ形の pass/fail が、ケース 1 では回帰、このケースでは意図した変更になる。違いは diff ではなくコミットメッセージにある。だから判定はツールの外に置いている。
