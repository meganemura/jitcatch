# jitcatch

Ruby 向けの Just-in-Time catching test の決定的なプロトタイプ。変更ごとに、その diff を狙ったテストを **親（base）と変更後（head）の両方**で走らせ、base で通り head で落ちるものだけを残す。フレークは落とし、明らかな非シグナルはルールで捨て、残りをエージェントが「意図した変更か、回帰か」を判断する。

**このツールは LLM を呼ばない。** テストを書くのも、意図を判断するのも、Claude Code や Cursor や人間である。CLI は短い文脈を作り、テストを実行し、分類するだけ。

Ruby 3.3 以降（4.0 でも可）。追加 gem はない。`minitest` と `prism` は標準添付。動作確認は Ruby 3.3.13。

## 設計

対象は git リポジトリの 2 つのコミット。出力は同じ入力ならバイト単位で同じになる。並びは固定、コンパクトな出力に時刻は出さない。テストの順序は Minitest の `--seed 1`。ワークツリーの絶対パスは結果から除く。どのコマンドも `--json` で同じ内容の JSON を出す。

```
jitcatch context [--json] [--repo DIR] [--coverage FILE] BASE HEAD
jitcatch run     [--json] [--repo DIR] [--coverage FILE] [--reruns N] [--timeout SEC] BASE HEAD TESTS_DIR
jitcatch assess  [--json] RUN.json
```

終了コードは 0 が成功、1 が使い方の誤り、2 が git の失敗。候補が見つかっても 0 のまま。回帰かどうかはツールが決めない。

`context` はエージェント向けの短いブリーフを出す。

- 変更されたファイル
- Prism で diff のハンクをメソッドに対応づける。メソッドごとの安定な id（`m01`…）
- 各メソッドの旧ソースと新ソース。定数だけが変わったときは、その定数を読むメソッドを `affected` として出す（`k01`）
- 変更メソッドの呼び出し元（ライブラリ内）と、そこから届く公開エントリ
- 既存テストの参照。既定はテストファイルの grep。`--coverage` を渡すとそのファイルだけを使う

`run` は一時ディレクトリに base と head の git worktree を作り、候補ファイルをそれぞれ `.jitcatch/` にコピーして、ファイルごとに `ruby -Ilib -I.` で実行する。タイムアウトは既定 10 秒。分類は次のとおり。

| 結果 | 意味 |
| --- | --- |
| pass / pass | `no_signal`。証拠にならない |
| pass / fail | catching candidate。古いコードが満たしていた主張を、新しいコードが壊した |
| base で失敗 | `fail_on_base`。テストが壊れているか、新機能だけを書いている。捨てる |
| 候補を head で再実行 | 既定 2 回。1 回でも結果が変われば `flaky` として捨てる |
| LoadError、タイムアウト、シグネチャ変更に伴う NameError / NoMethodError / 引数個数の ArgumentError | `discarded` |

`assess` はルールだけを適用する。残った候補について、テスト名、base と head の結果、失敗メッセージの先頭、関連メソッド id、タグを出す。タグは `touches:changed_method`（テストがそのメソッド名を呼んでいる）と `touches:unchanged_caller`（変更していない入口から、変更されたメソッドへ届いている）のどちらか、または両方。複数の変更メソッドが経路上にあるときは、追加されたメソッドより、もともとあったメソッドのうち最も下流のものを関連 id にする。

意図した変更と回帰の切り分けはしない。それはエージェントの仕事で、手順は [skills/jitcatch/SKILL.md](skills/jitcatch/SKILL.md) にある。

## 実行

```sh
ruby script/setup_shop          # examples/shop に再現可能な git 履歴を作る
bin/jitcatch context --repo examples/shop base regression
bin/jitcatch run --repo examples/shop base regression examples/runs/regression/tests
ruby -Ilib test/run.rb          # エンジンテスト
```

`examples/shop` は生成物なのでリポジトリには入らない。中身のソースは `examples/fixtures/shop/` にある。

候補テストは対象リポジトリへコミットしない。このリポジトリの `examples/runs/` は、デモでエージェント役をやった記録である。

## エージェントのループ

1. `jitcatch context BASE HEAD` を読む。意図は `BASE..HEAD` のコミットメッセージとして出る。
2. 変更メソッドと、その近くの変わっていない振る舞い（境界、丸め、異常系）に対して、Minitest を 3〜6 ファイル書く。
3. `jitcatch run BASE HEAD tests_dir/` を実行する。
4. reported の各行を、意図と照らして likely-regression / intended / unclear に分ける。
5. カウントと判断を短いレポートに書く。テストは捨てる。

新機能だけを assert するテストは base で落ち、候補にならない。catching test は「古いコードがすでに満たしていること」を書く。

## コーディングエージェントと使う

レビューや取り込みのときにエージェントが踏む手順は [skills/jitcatch/SKILL.md](skills/jitcatch/SKILL.md) にある。[AGENTS.md](AGENTS.md) はこのリポジトリを変更する人向け。

スキルを入れるには、`skills/jitcatch` をエージェントの skills ディレクトリへコピーまたはシンボリックリンクする（例: `.agents/skills/`、`.claude/skills/`、`.cursor/skills/`）。実行ファイル `bin/jitcatch`（Ruby 3.3 以降）は別途 `PATH` に置く。スキルをコピーしても実行ファイルは入らない。

## Meta のパイプラインとの対応

Meta の Just-in-Time Catching Test Generation（arXiv 2601.22832、engineering.fb.com の 2026-02-11 と 2026-10-29）は、変更のたびに diff 向けのテストを生成し、親と head で走らせ、親で成功し head で失敗するものだけを残す。再実行でフレークを落とし、ルールと LLM の判定で「意図した振る舞いの変更」と「回帰らしい失敗」を分け、回帰だけを報告する。テストは使い捨て。

Vitest での実験（github.com/hbmartin/catching-jit-tests-vitest）も、同じ pass/fail フィルタを外に出している。

| Meta | jitcatch |
| --- | --- |
| 変更の選択 | `git diff BASE HEAD` と Prism |
| テスト生成（モデル） | エージェントが `context` を読んで Minitest を書く |
| base と head で実行 | worktree を作り、ファイルごとに `ruby` |
| pass/fail だけ残す | `candidate` |
| フレーク除去 | `--reruns`（既定 2） |
| ルール判定 + LLM 判定 | ルールは `assess`。意図の判断はエージェント |
| 回帰の報告 | エージェントが書く最終レポート |
| テストは捨てる | 対象リポジトリには入れない |

## デモ

`examples/fixtures/shop` はセント単位のカート（base のライブラリは 73 行）。10% のボリューム割引は小計 10000 セント以上、税は 8% で half-up。既存テストは 4000 と 15000 と、12 セントの丸めだけを見ており、10000 ちょうどは見ていない。

`ruby script/setup_shop` が作る履歴は固定の作者と日付なので、コミット SHA は環境が同じなら一致する。

| ブランチ | SHA | 内容 |
| --- | --- | --- |
| base | `cf7f35144524b7a0606df29197ac609b2f17773f` | 初期実装 |
| regression | `f2f5f6c3778bca3f65d06728583ca9e089523dfc` | SAVE5 を足し、閾値の比較を `<` から `<=` に変えた。メッセージはクーポンの話だけ |
| intended | `f8505c45e71a6f219d1e0dfa26728c296b4d2d42` | 閾値を 5000 に下げる。メッセージがその変更だと明記している |

既存の `test/test_cart.rb` は 3 つのどれでも通る。回帰は元のスイートの穴に入っている。

### ケース 1: 機能追加と、既存境界の回帰

意図は「SAVE5 は税引前に 500 セント」。`context` の m05 はこう出る（全文は `examples/runs/regression/context.txt`、93 行）。

```
  [m05] modified Shop::Cart#volume_discount_cents lib/shop/cart.rb:50-54 signature=same visibility=public
    callsites: lib/shop/cart.rb:57 Shop::Cart#taxable_cents
    reachable_from: Shop::Cart#tax_cents, Shop::Cart#taxable_cents, Shop::Cart#total_cents
    tests: test/test_cart.rb grep
    old:
      def volume_discount_cents
        return 0 if subtotal_cents < VOLUME_THRESHOLD_CENTS

        Money.percent(subtotal_cents, VOLUME_PERCENT)
      end
    new:
      def volume_discount_cents
        return 0 if subtotal_cents <= VOLUME_THRESHOLD_CENTS

        Money.percent(subtotal_cents, VOLUME_PERCENT)
      end
```

このブリーフを読んで書いたテストは 5 ファイル、13 メソッド。境界（9999 / 10000 / 10001）、10000 の合計、丸め、入力チェック、SAVE5。実行結果（`examples/runs/regression/run.txt`）:

```
counts generated=13 no_signal=8 fail_on_base=3 candidates=2 flaky=0 discarded=0 reported=2
assess:
  c01 ThresholdTotalTest#test_at_threshold_total_includes_the_volume_discount base=pass head=fail m05 assertion,report,touches:unchanged_caller
    Expected: 9720
    Actual: 10800
  c02 VolumeBoundaryTest#test_threshold_is_inclusive base=pass head=fail m05 assertion,report,touches:changed_method
    Expected: 1000
    Actual: 0
```

判断はどちらも **likely-regression**。10800 は割引なしの税込み、9720 は割引後で、どちらも `<=` が 10000 ちょうどを割引から外したことが原因。意図はその変更を頼んでいない。SAVE5 の 3 件は base で落ちる（`apply_coupon` が無くて `NoMethodError` が 2 件、`Shop::UnknownCoupon` が無くて `NameError` が 1 件）。候補にならない。丸めと 9999 / 10001 は pass/pass。flaky は 0、ルールで捨てた候補も 0。unclear はない。

報告は 2 テスト、中身は回帰 1 種類。詳細は `examples/runs/regression/report.md`。

### ケース 2: 意図した振る舞いの変更

定数だけが変わる。メソッド本体は同じなので、`affected` として出る（全文は `examples/runs/intended/context.txt`、35 行）。

```
constants:
  [k01] modified Shop::Cart::VOLUME_THRESHOLD_CENTS lib/shop/cart.rb:7
    old: VOLUME_THRESHOLD_CENTS = 10_000
    new: VOLUME_THRESHOLD_CENTS = 5_000
    readers: m01
methods:
  [m01] affected Shop::Cart#volume_discount_cents lib/shop/cart.rb:30-34 signature=same visibility=public via=k01
```

9 メソッド。古い境界をそのまま書いたものと、新しい規則を直接書いたもの、丸めと数量チェック。結果（`examples/runs/intended/run.txt`）:

```
counts generated=9 no_signal=6 fail_on_base=1 candidates=2 flaky=0 discarded=0 reported=2
assess:
  c01 ThresholdTest#test_between_old_and_new_threshold_total_had_no_discount base=pass head=fail m01 assertion,report,touches:unchanged_caller
    Expected: 8100
    Actual: 7290
  c02 ThresholdTest#test_five_thousand_had_no_discount base=pass head=fail m01 assertion,report,touches:changed_method
    Expected: 0
    Actual: 500
```

判断はどちらも **intended**。5000 セント以上を 10% にする、と意図が書いている。7500 の合計が 8100 から 7290 になるのはその範囲。新しい規則を直接書いたテストは base で落ち、候補にならない。likely-regression は 0。unclear はない。flaky も 0。

同じ pass/fail が、ケース 1 では回帰、ケース 2 では意図した変更になる。差は diff の形ではなくコミットメッセージにある。

## なぜツールの中で LLM を呼ばないか

- **決定性。** 同じリポジトリと同じテストなら、出力はバイト単位で一致する。エンジンテストがデモの記録と突き合わせている。モデルの版や温度で結果が変わらない。
- **費用。** 生成も判断も、すでにエージェントに払っているモデルで足りる。CLI が毎回 API を叩く必要はない。
- **どのエージェントでも駆動できる。** Claude Code でも Cursor でも人間でも、同じコマンド列になる。ツールが特定のモデルに縛られない。
- **意図の判断は、PR の文章と会話が要る。** それはエージェントがすでに持っている。CLI に一つの判定モデルを埋め込むと、その選択が固定され、テストもできなくなる。

## 制限

正直に書いておく。

- 呼び出しは名前ベースで、型を見ていない。同名メソッドが複数あると、呼び出し元を落としたり、関連 id を外したりする。
- `define_method` や `class_eval`、条件の中の `def` は索引しない。`def self.foo` 以外のレシーバ付き定義も粗い。
- リネームは `--no-renames` なので削除と追加に見える。
- カバレッジは自分では集めない。`--coverage` の JSON を読むだけ。
- ルールはシグネチャ変更、LoadError、タイムアウトを捨てるだけ。`ArgumentError` でも `qty must be > 0` のような明示的なものは残す。意図と回帰は分けない。
- 候補テストが古い振る舞いを書いていなければ、回帰は見つからない。今回のバグは既存スイートの穴で、境界のテストを書かなかった場合 reported は 0 のまま。
- 新機能のテストは base で落ちて消える。それは仕様で、回帰検出の代わりにはならない。
- 関連 id はヒューリスティックである。失敗の原因がもう一つ上流にあることもある。
- 言及はテストメソッドのソースの単語。コメントにメソッド名を書くとタグが寄る。
- タイムアウトは再実行しない。1 ファイルずつで、並列ではない。
- 対象の既存スイートは走らせない。ワークツリーが使える git リポジトリが要る。
- アサーション失敗のバックトレースはテスト側で止まりがちなので、ライブラリ行へのタグはメソッド名の言及に頼る。

## 次のステップ

**simplecov のテスト単位カバレッジ。** いま受け付ける形は `jitcatch-coverage-v1`（例は `examples/coverage/jitcatch-coverage-v1.sample.json`）。

```json
{
  "format": "jitcatch-coverage-v1",
  "tests": [
    {
      "id": "TestCart#test_volume_discount_above_threshold",
      "file": "test/test_cart.rb",
      "lines": { "lib/shop/cart.rb": [30, 31, 32, 33, 34] }
    }
  ]
}
```

`--coverage` を渡すと grep の代わりに、変更メソッドの行範囲と重なるテストだけをブリーフへ出す。simplecov の per-test 結果、または `simplecov affected` が挙げる変更行を、この JSON に変換するアダプタが次の一段。収集自体はツールの外に置く。

**hegel-ruby（gem `hegeltest`）のプロパティテストを、生成するテストの形にする。** 境界を 1 点ずつ書く代わりに、割引の閾値や丸めの性質をプロパティで書く。実行と比較は今の pass/fail フィルタのまま。gem は入れていない。

**GitHub Actions の `@jitcatch` コメント。** PR コメントをトリガに context を出し、エージェントがテストとレポートを書き、コメントで返す。アカウントもワークフローも、このプロトタイプには作っていない。

**一回きりの E2E へ広げる。** 同じ base/head フィルタを、変更した入口を 1 度だけ叩くリクエストやブラウザのスモークに使う。テストはやはり捨てる。

**LLM を中に置いた変種との比較。** 中にモデルを置く CLI は、テスト生成も intended / regression の判定もコマンドの中でやる。出力はバイト安定でなくなり、秘密と費用が要り、エンジンテストで固定できない。このプロトタイプは逆で、モデルはループの外、ツールは純関数。ハイブリッドにするなら、既定は今のままにして、明示したときだけ外のコマンドへ委譲する。

## 開発

このリポジトリを変更するエージェント向けのメモは [AGENTS.md](AGENTS.md)。

```sh
ruby -Ilib test/run.rb
```

エンジンテストは一時 git リポジトリで context、実行、フレーク、タイムアウト、シグネチャ変更の破棄を見る。ショップのデモは `test/jitcatch/test_shop_demo.rb` が、記録した `context.txt` と `run.txt` を新しいフィクスチャの出力とバイト比較する。
