# jitcatch

jitcatch は、変更の親で通り、その変更で落ちる Ruby のテストを残す。

変更をレビューするエージェントは、その差分向けのテストを書く。新しい振る舞いだけを書いたテストは親で落ち、回帰の証拠にならない。親がすでに満たしていて変更後に落ちるテストは、古いコードが満たしていた主張を新しいコードが壊したことを示す。jitcatch はそのテストを両方のリビジョンで走らせ、フレークと、ほかのいくつかの非シグナルを除いて、残ったものを出す。

方法は Meta の catching JiT tests に沿う（[Harden and Catch](https://arxiv.org/abs/2504.16472)、Meta での報告は [Just-in-Time Catching Test Generation at Meta](https://arxiv.org/abs/2601.22832)）。

## 使い方

Ruby 3.3 以降。追加の gem はない。`minitest` と `prism` は Ruby に付いている。`BASE` は親のリビジョン、`HEAD` は変更である。どちらもコミットを指す。未コミットのファイルは diff に入らない。

Minitest のファイルはスクラッチディレクトリに自分で書く。`require "minitest/autorun"` のあと、リポジトリがライブラリを読むのと同じ `require` を書く。実行は jitcatch が行う。`reported` の各行を、意図と diff と照らして判断する。ブリーフの意図は `BASE` から `HEAD` までのコミットメッセージである。各メッセージの末尾で git がトレーラーとして読む行（`Co-Authored-By:` など）は含めない。likely-regression は、振る舞いが変わり、意図がその変更を求めていないとき。intended は、意図がその変更を求めているとき。unclear は、意図だけでは決められないとき。

`examples/fixtures/shop` はセント単位のカートである。小計が 10000 セントに達すると 10% のボリューム割引が付く。税は 8% で、端数は half up。既存テストは 10000 セントちょうどを見ていない。`ruby script/setup_shop` は `examples/shop` に git の履歴を書く（このディレクトリは gitignore してある）。

| リビジョン | 内容 |
| --- | --- |
| `base` | 最初のカート。 |
| `regression` | SAVE5 クーポンを足し、閾値の比較を `<` から `<=` に変える。メッセージはクーポンのことだけを書く。 |
| `intended` | 閾値を 5000 セントに下げる。メッセージはその変更が意図的だと書く。 |

```sh
ruby script/setup_shop
bin/jitcatch context --repo examples/shop base regression
bin/jitcatch run --repo examples/shop base regression examples/runs/regression/tests
```

`context` は意図を出し、変更されたメソッドを 1 ブロックずつ出す。この実行からは次のとおり。

```
intent:
  Add SAVE5 coupon (500 cents off before tax).
  Apply the coupon with Cart#apply_coupon. SAVE5 subtracts 500 cents
  from the taxable amount before tax. Unknown codes raise
  Shop::UnknownCoupon.
```

`m05` は閾値のメソッドである。

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

`run` はテストを 2 件残す。全文は `examples/runs/regression/run.txt`。

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

reported の 2 件は、どちらも likely-regression である。10000 セントちょうどでは割引が 1000、割引後の税込み合計が 9720 になる。head は 0 と 10800 を返す。10800 は割引なしの税込み合計である。意図が頼んでいるのはクーポンの追加だけである。SAVE5 の 3 件は base で落ちる。`apply_coupon` と `Shop::UnknownCoupon` がまだ無いためで、候補にならない。

もう一方の履歴は、意図した変更である。変わるのは定数だけで、メソッド本体は同じなので、`context` はそのメソッドを `affected` と出す。

```sh
bin/jitcatch context --repo examples/shop base intended
bin/jitcatch run --repo examples/shop base intended examples/runs/intended/tests
```

```
constants:
  [k01] modified Shop::Cart::VOLUME_THRESHOLD_CENTS lib/shop/cart.rb:7
    old: VOLUME_THRESHOLD_CENTS = 10_000
    new: VOLUME_THRESHOLD_CENTS = 5_000
    readers: m01
methods:
  [m01] affected Shop::Cart#volume_discount_cents lib/shop/cart.rb:30-34 signature=same visibility=public via=k01
```

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

全文は `examples/runs/intended/context.txt` と `examples/runs/intended/run.txt`。reported の 2 件は intended である。メッセージは、5000 セント以上の注文を 10% 引きにする、と書いている。新しい規則を直接書いたテストは base で落ち、候補にならない。base で通り head で落ちる結果の形は、回帰の実行と同じである。分けているのはコミットメッセージである。

終わったらスクラッチディレクトリは消す。プロジェクトのスイートに残すのは、そのテストを採用するときだけである。likely-regression のテストは、バグを直したあとに置ける。intended のテストは、古い振る舞いを書いている。

別のリポジトリでは、そのリポジトリが作業ディレクトリでなければ `--repo` を渡す。

```sh
jitcatch context --repo DIR BASE HEAD
jitcatch run --repo DIR BASE HEAD TESTS_DIR
```

### オプション

| フラグ | コマンド | 効果 |
| --- | --- | --- |
| `--json` | `context`, `run`, `assess` | 同じ内容を JSON で出す。 |
| `--repo DIR` | `context`, `run` | 読む git リポジトリ。既定は作業ディレクトリ。 |
| `--coverage FILE` | `context`, `run` | 既存テストの grep の代わりにこのファイルを使う。JSON は `"format": "jitcatch-coverage-v1"` と `tests` 配列を持つ。例は `examples/coverage/jitcatch-coverage-v1.sample.json`。 |
| `--reruns N` | `run` | base で通り head で落ちたあとの、head での追加実行回数。既定は 2。`0` でフレーク検査をしない。 |
| `--timeout SEC` | `run` | テストファイルを止めるまでの秒数。既定は 10。最小は 1。 |
| `--env NAME` | `run` | この環境変数を今の環境からテストのプロセスへ渡す。複数の名前は繰り返して渡す。実行結果には値ではなく名前を記録する。 |

| コマンド | 引数 |
| --- | --- |
| `jitcatch context` | `BASE HEAD` |
| `jitcatch run` | `BASE HEAD TESTS_DIR` |
| `jitcatch assess` | `run --json` が書いた `RUN.json` |

`assess` は件数と候補の行を再出力する。掛けるルールは `run` と同じである。

```sh
bin/jitcatch run --json --repo examples/shop --reruns 2 --timeout 10 base regression examples/runs/regression/tests > run.json
bin/jitcatch assess run.json
bin/jitcatch assess --json run.json
```

| 終了コード | 意味 |
| --- | --- |
| 0 | コマンドは完了した。候補が見つかっても 0 のまま。 |
| 1 | 使い方の誤り。 |
| 2 | git の失敗。 |

### 結果

| 区分 | 意味 |
| --- | --- |
| `no_signal` | base でも head でも通った。 |
| `fail_on_base` | 親がそのテストを満たさなかった。新しい機能だけを書いていることが多い。 |
| `flaky` | base で通り head で落ちたあと、再実行が同じ落ち方をしなかった。捨てる。 |
| `discarded` | base で通り head で落ちたあと、ルールが除いた。`assess:` には残る。 |
| `reported` | base で通り head で落ち、ルールは除かなかった。この行を判断する。 |

`generated` はテストメソッドの数である。`candidates` は、破棄ルールの前に、base で安定して通り head で落ちた数である。`reported` はそのあと残った数である。

タグはヒントであり、判断そのものではない。`touches:changed_method` は、テストが diff の変更したメソッド名を含んでいる。`touches:unchanged_caller` は、diff が編集していない入口を通り、その入口から変更メソッドへ届いている。`discard:signature_change`、`discard:load_error`、`discard:timeout` は、候補を除いたルールの名前である。関連 id（`m05`、無ければ `-`）は、経路上に変更メソッドが複数あるときの、最も下流の変更メソッドである。

## どう残すか

`context` は 2 つのリビジョンを diff し、ハンクを Prism でメソッドに対応づける。変更メソッドは `m01`、`m02` と付く。変わった定数は `k01` で、その定数を読むだけで本体が変わっていないメソッドは `affected`（`via=k01`）になる。片方の側にしか無いクラスやモジュールも定数として `added` か `removed` になり、ソースには宣言の行が出る。各メソッドには、旧ソースと新ソース、ライブラリ内の呼び出し、そこへ届く入口（`reachable_from`）、それに言及している既存テストが出る。言及しているテストがないときは `entry_point_tests` が出る。`reachable_from` のうち public な入口について、そのクラスを書き、入口と同じ名前のメソッドを呼んでいるテストファイルである。`--coverage` を渡すと、grep の代わりに JSON の行リストを使う。

`run` はリビジョンごとに git worktree を作り、スクラッチディレクトリをその worktree の `.jitcatch/` へコピーし、ファイルごとに 1 プロセスで実行する。

```sh
ruby -Ilib -I. .jitcatch/<file> -v --seed 1
```

リビジョンに `Gemfile` があるときは、`-rbundler/setup` を付け、`BUNDLE_GEMFILE` をその `Gemfile` にして実行する。そのため、それぞれの側は自分のロックファイルにある gem を読む。`run` は側ごとに 1 回 bundle を確かめ、`bundle base ok` や `bundle head failed: <メッセージ>` を出す。たとえばロックした gem がインストールされていないときである。プロセスに渡す環境変数は、決まった一覧と `--env` で名前を挙げたものだけである。

実行されるのは `*_test.rb` か `test_*.rb` である。その名前が 1 つも無いときは、すべての `.rb` を実行する。上限は 40 ファイル。base で通り、head で失敗、エラー、またはタイムアウトになったテストが候補になる。`--reruns` は候補を head で繰り返す。1 回でも結果が違えば `flaky` である。比べる前に一時ディレクトリ直下の名前を伏せるので、メッセージにある `Dir.mktmpdir` のパスは違いにならない。テキストの報告は `flaky` の行の下に各再実行の結果を出し、JSON の行は `reruns` に持つ。タイムアウトは再実行しない。

候補を `discarded` にするルールは 3 つある。head での `LoadError`、タイムアウト、そして diff が消したかシグネチャを書き換えた名前に対する `NameError`、`NoMethodError`、引数個数の `ArgumentError` である。消えたクラスやモジュールも消えた名前に数える。コードが意図して起こす `ArgumentError`（`qty must be > 0` のようなもの）は `reported` のまま残る。

同じリポジトリと同じテストなら、出力は同じバイトになる。順序は固定で、テキストに時刻は無く、worktree の絶対パスは除かれる。

## インストール

実行ファイルは、このリポジトリのチェックアウトにある `bin/jitcatch` である。そのディレクトリを `PATH` に置く。

スキルは [`skills`](https://github.com/vercel-labs/skills) CLI で入れる（Node.js 22.20 以降）。このリポジトリは非公開なので、Git の認証情報、GitHub CLI、または SSH で GitHub にアクセスできる必要がある。

```sh
npx skills add meganemura/jitcatch
```

このスキルだけ、グローバル、または特定のエージェントへ入れる。

```sh
npx skills add meganemura/jitcatch --skill jitcatch
npx skills add meganemura/jitcatch -g
npx skills add meganemura/jitcatch -a cursor
npx skills add meganemura/jitcatch -a claude-code
```

確認を飛ばすときは `-y` を足す。`bin/jitcatch` も `PATH` に置く。

CLI を使わない場合は、`skills/jitcatch` をエージェントの skills ディレクトリへコピーまたはシンボリックリンクする（例: `.agents/skills/`、`.claude/skills/`、`.cursor/skills/`）。

## 限界

- 呼び出しは名前で照合し、型は見ない。同名のメソッドが複数あると、呼び出し元を落とすか、関連 id を外す。
- `define_method`、`class_eval`、条件の中の `def` は索引しない。`def self.foo` 以外のレシーバ付き定義は粗い。
- リネームは削除と追加に見える（`git diff --no-renames`）。
- カバレッジは集めない。`--coverage` は渡された JSON を読むだけである。
- 破棄ルールは、intended と regression を分けない。
- 候補テストが古い振る舞いを書いていなければ、その穴にある回帰は `reported` が 0 のままである。
- 新機能のテストは base で落ち、候補にならない。
- 関連 id は、失敗の原因の行から一段ずれていることがある。
- 言及は、そのテストメソッドの中の語である。コメントにメソッド名を書くと、タグがそちらへ寄る。
- ファイルは 1 つずつ実行する。リポジトリの既存スイートは走らない。worktree を追加できる git リポジトリが要る。
- アサーションのバックトレースはテストの中で止まりがちなので、ライブラリの行はテストが言及した名前から探す。

## 開発

```sh
ruby -Ilib test/run.rb
```

エンジンテストは一時 git リポジトリを作り、context、実行、フレーク、タイムアウト、シグネチャ変更の破棄を見る。`test/jitcatch/test_shop_demo.rb` はショップのフィクスチャを作り直し、`context` と `run` を `examples/runs/*/context.txt` および `run.txt` とバイト単位で比べる。

## ライセンス

ライセンスはまだ選んでいない。
