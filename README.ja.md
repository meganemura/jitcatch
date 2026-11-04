# jitcatch

jitcatch は、変更の親で通り、その変更で落ちる Ruby のテストを残す。

変更をレビューするエージェントは、その差分向けのテストを書く。
新しい振る舞いだけを書いたテストは親で落ち、回帰の証拠にならない。
親がすでに満たしていて変更後に落ちるテストは、古いコードが満たしていた主張を新しいコードが壊したことを示す。
jitcatch はそのテストを両方のリビジョンで走らせ、フレークと、ほかのいくつかの非シグナルを除いて、残ったものを出す。

方法は Meta の catching JiT tests に沿う（[Harden and Catch](https://arxiv.org/abs/2504.16472)、Meta での報告は [Just-in-Time Catching Test Generation at Meta](https://arxiv.org/abs/2601.22832)）。

## 使い方

Ruby 3.3 以降。
追加の gem はない。
`minitest` と `prism` は Ruby に付いている。
RSpec の候補には、実行する場所に `rspec-core` が要る。
プロジェクトの bundle に入れるか、`Gemfile` が無いプロジェクトならその Ruby にインストールしておく。
`BASE` は親のリビジョン、`HEAD` は変更である。
どちらもコミットを指す。
未コミットのファイルは diff に入らない。

候補のファイルはスクラッチディレクトリに自分で書く。
Minitest のファイルは `require "minitest/autorun"` で始め、リポジトリがライブラリを読むのと同じ `require` を書く。
RSpec のファイルは `*_spec.rb` という名前にし、プロジェクト自身の spec と同じく `require "spec_helper"` か `require "rails_helper"` で始める。
実行は jitcatch が行う。
`reported` の各行を、意図と diff と照らして判断する。
ブリーフの意図は `BASE` から `HEAD` までのコミットメッセージである。
各メッセージの末尾で git がトレーラーとして読む行（`Co-Authored-By:` など）は含めない。
likely-regression は、振る舞いが変わり、意図がその変更を求めていないとき。
intended は、意図がその変更を求めているとき。
unclear は、意図だけでは決められないとき。

`examples/fixtures/shop` はセント単位のカートである。
小計が 10000 セントに達すると 10% のボリューム割引が付く。
税は 8% で、端数は half up。
既存テストは 10000 セントちょうどを見ていない。
`ruby script/setup_shop` は `examples/shop` に git の履歴を書く（このディレクトリは gitignore してある）。

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

`context` は意図を出し、変更されたメソッドを 1 ブロックずつ出す。
この実行からは次のとおり。

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

`run` はテストを 2 件残す。
全文は `examples/runs/regression/run.txt`。

```
counts generated=13 no_signal=8 fail_on_base=3 candidates=2 flaky=0 discarded=0 reported=2
assess:
  c01 ThresholdTotalTest#test_at_threshold_total_includes_the_volume_discount base=pass head=fail m05 assertion,related:guess,report,touches:unchanged_caller
    related guess: m05 of m02,m04,m05
    Expected: 9720
    Actual: 10800
  c02 VolumeBoundaryTest#test_threshold_is_inclusive base=pass head=fail m05 assertion,report,touches:changed_method
    Expected: 1000
    Actual: 0
```

reported の 2 件は、どちらも likely-regression である。
10000 セントちょうどでは割引が 1000、割引後の税込み合計が 9720 になる。
head は 0 と 10800 を返す。
10800 は割引なしの税込み合計である。
意図が頼んでいるのはクーポンの追加だけである。
SAVE5 の 3 件は base で落ちる。
`apply_coupon` と `Shop::UnknownCoupon` がまだ無いためで、候補にならない。

もう一方の履歴は、意図した変更である。
変わるのは定数だけで、メソッド本体は同じなので、`context` はそのメソッドを `affected` と出す。

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

全文は `examples/runs/intended/context.txt` と `examples/runs/intended/run.txt`。
reported の 2 件は intended である。
メッセージは、5000 セント以上の注文を 10% 引きにする、と書いている。
新しい規則を直接書いたテストは base で落ち、候補にならない。
base で通り head で落ちる結果の形は、回帰の実行と同じである。
分けているのはコミットメッセージである。

終わったらスクラッチディレクトリは消す。
プロジェクトのスイートに残すのは、そのテストを採用するときだけである。
likely-regression のテストは、バグを直したあとに置ける。
intended のテストは、古い振る舞いを書いている。

branchout の特性テストも、Minitest のファイルとしても RSpec の spec（`--format rspec`）としても候補にできる。
base のリビジョンのチェックアウトで `--require-by-name` を付けて出力する。
そうすると、それぞれの側が自分のワークツリーのコードを読み込む。
これを付けずに出力したテストは `require_relative` か絶対パスを持つ。
チェックアウトの `.jitcatch/` の下に出力したテストのように、そのパスがワークツリーの中を指すなら問題ない。
ワークツリーの外を指すと、両側が同じファイルを読み、すべての行が `no_signal` になる。

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
| `--coverage FILE` | `context` | 既存テストの grep の代わりにこのファイルを使う。JSON は `"format": "jitcatch-coverage-v1"` と `tests` 配列を持つ。例は `examples/coverage/jitcatch-coverage-v1.sample.json`。 |
| `--reruns N` | `run` | base で通り head で落ちたあとの、head での追加実行回数。既定は 2。`0` でフレーク検査をしない。 |
| `--timeout SEC` | `run` | テストファイルを止めるまでの秒数。既定は 10。最小は 1。 |
| `--workers N` | `run` | 同時に実行するテストファイルの数。ワーカーごとに base と head の worktree を持つ。既定は 1。1 つのワーカーは Ruby プロセスを 2 つ同時に動かすので、ワーカーを増やして速くなるのは CPU が空いているときだけである。N によらずレポートは同じになる。 |
| `--serial` | `run` | Ruby プロセスを 1 つずつ動かす。ファイルの base 側を走らせてから head 側を走らせる。worktree の外の決まったパスに書く候補や、決まったポートで待ち受ける候補のためのものである。`--workers` に 1 より大きい値は渡せない。テキストのレポートは `serial` と出し、`--json` は `"serial": true` を記録する。 |
| `--env NAME` | `run` | この環境変数を今の環境からテストのプロセスへ渡す。複数の名前は繰り返して渡す。実行結果には値ではなく名前を記録する。設定されていない名前は `env_unset` 行に出す。 |

| コマンド | 引数 |
| --- | --- |
| `jitcatch context` | `BASE HEAD` |
| `jitcatch run` | `BASE HEAD TESTS_DIR` |
| `jitcatch assess` | `run --json` が書いた `RUN.json` |

最初のコミットを見るときは、`BASE` に `ROOT^` を渡す。
ルートコミットの親は空のツリーとして読む。

`BASE` が `HEAD` の祖先でないとき、diff は `BASE` にしかないコミットも打ち消す。
そのとき `context` と `run` は `head` の下に `warning:` 行を出す。
その行は、そのコミットの数と、代わりに `BASE` に渡すマージベースを示す。
2 つが同じコミットを指すときも、`warning:` 行がそう示す。

`assess` は run の警告、件数、候補の行を再出力する。
掛けるルールは `run` と同じである。
行には失敗の最初の行か、Minitest の差分の期待行と実際行が出る。
そのどちらかが 100 文字を超えると、値の違う Hash のエントリか Array の要素か、最初に違う桁のまわりと `^ column N` の印を出す。
この印は、追加行が削除行を置き換えるときだけ出る。
差分の別々の場所にある 2 行は、それぞれ 61 文字で切る。
失敗した `assert_raises(X)` の行には、代わりに来たエラーを示す Minitest の `Class:` 行と `Message:` 行も出る。
別のエラーから上げられたエラーの行には、`cause: KeyError: key not found` のように元のエラーのクラスとメッセージが出る。
RSpec は元のエラーを自分で出力する。
Minitest は出力しないので、jitcatch は Minitest の候補の各プロセスに `-r` で `lib/jitcatch/minitest_cause.rb` を読み込み、Minitest のエラーの文に元のエラーを足す。
`rerun:` の行はこれを読み込まない。
行の 1 行が 300 文字を超えると、`FrozenError` に出た凍結 Array 全体のような行もそこで切り、`... (+N more; the whole message is in --json)` で終える。
`--json` はメッセージ全体を残す。

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
| 3 | `run` は行を出さずに止まった。ある側がセットアップの確認に失敗したか、どちらの側でも候補ファイルが 1 つも読み込めなかった。 |

### 結果

| 区分 | 意味 |
| --- | --- |
| `no_signal` | base でも head でも通った。 |
| `fail_on_base` | 親がそのテストを満たさなかった。新しい機能だけを書いていることが多い。 |
| `flaky` | base で通り head で落ちたあと、再実行が同じ落ち方をしなかった。捨てる。 |
| `discarded` | base で通り head で落ちたあと、ルールが除いた。`assess:` には残る。 |
| `reported` | base で通り head で落ち、ルールは除かなかった。この行を判断する。 |

`generated` はテストメソッドの数である。
`candidates` は、破棄ルールの前に、base で安定して通り head で落ちた数である。
`reported` はそのあと残った数である。

タグはヒントであり、判断そのものではない。
`touches:changed_method` は、テストが diff の変更したメソッド名を含んでいる。
`Owner.new` は、その `Owner` の `initialize` だけの名前として数える（`Mismatch.new` は `Spec#initialize` を指さない）。
変更したコンストラクタが関連メソッドになるのは、テストがほかの変更メソッドの名前を含まず、その呼び出し元も通らないときだけである。
`touches:changed_constant` は、テストが diff の変更した定数名を含んでいる。
`touches:changed_dependency` は、ロックしたバージョンが変わった gem の中からエラーが出た。
gem の中から始まったエラーには `touches:changed_method` を付けない。
`touches:unchanged_caller` は、diff が編集していない入口を通り、その入口から変更メソッドへ届いている。
`discard:signature_change`、`discard:load_error`、`discard:timeout`、`discard:no_database` は、候補を除いたルールの名前である。
`discard:signature_change` は、削除したメソッドや新しいシグネチャが壊した呼び出しを、テスト自身がしているときだけ使う。
変更されていないコードがその呼び出しをしているときは、行を報告する。
たとえば `class B < A` が、head で削除した `A#helper` をまだ呼んでいるときである。
その行には、呼び出しの位置を示す `caller:unchanged:lib/b.rb:5` を付ける（diff が書いた行か、変更メソッドの中の行なら `caller:changed:`。`--json` の `changed_lines` は、各ファイルの hunk が書いた head の行を並べる）。
関連 id（`m05`、無ければ `-`）は、経路上に変更メソッドが複数あるときの、最も下流の変更メソッドである。
失敗のバックトレースが変更メソッドを通るときは、そのうち最も内側のものである。
フレームの行は head の行として読むので、base でその行にあったメソッドには当たらない。
外側のフレームはそれを呼んだだけなので、この選択は推測ではない。
`related:guess` は、id を選んだ根拠が複数の変更メソッドを指している。
たとえば、テストが変更されていない呼び出し元だけを含み、その呼び出し元から複数の変更メソッドへ届くときである。
その行の次の行 `related guess: m05 of m02,m04,m05` が候補をすべて並べ、`--json` では `method_ids` が同じものを持つ。
この選択は、diff が追加したメソッドより base にあったメソッドを選ぶ。
ただし、追加したメソッドの呼び出しを足しただけの編集（`--json` の `forwards_to_added`）は、その追加したメソッドより下に置く。
`net - volume` が `net - volume - coupon(n)` になる編集がその例で、新しい値は追加したメソッドから来る。
`related:dynamic` は、関連する変更メソッドはないが、テストが `dynamic_callers:` のメソッドを呼んでいる。
その行の次の行が `related: none, Emit.looked_up sends render to a receiver the source does not name` のようにそれを言う。

## どう残すか

`context` は 2 つのリビジョンを diff し、ハンクを Prism でメソッドに対応づける。
変更メソッドは `m01`、`m02` と付く。
`Gemfile.lock` が変わったときは、`dependencies:` に gem ごとに `gem 旧 -> 新` を出す。
変わった定数は `k01` で、その定数を読むだけで本体が変わっていないメソッドは `affected`（`via=k01`）になる。
あるファイルから消えたメソッドを、head が別のファイル（テストファイルも含む）で同じ名前で定義していれば、それは `moved` になる。
新しい場所で出し、`moved_from=` が元のファイルを示す。
複数のファイルが定義しているときは、diff が触ったファイルを先に選ぶ。
`attr_reader`、`attr_writer`、`attr_accessor`、`Struct.new` や `Data.define` のメンバーが定義する読み書きのメソッドもメソッドとして数え、ソースには名前一つの形（`attr_reader :seed`）が出る。
そのため、その行から外した名前は `removed` になり、行に残った名前は変わらない。
`*FIELDS` の形で渡したリストも、同じファイルがその前に `FIELDS = %i[x y].freeze` のようにシンボルのリストを入れていれば数える。
このとき各メンバーは、そのリストの中の自分のシンボルの行を持つ。
クラス本体の条件分岐の中にある `def` や読み出しメソッド（`attr_reader :x if cond`）も数える。
分岐はすべてが順に走ったものとして読むので、分岐の中の引数のない `private` は条件分岐の後にも効く。
Concern の `included do`、`prepended do`、`class_methods do` ブロックの中にあるものも数える。
片方の側にしか無いクラスやモジュールも定数として `added` か `removed` になり、ソースには宣言の行が出る。
各メソッドには、旧ソースと新ソース、ライブラリ内の呼び出し、そこへ届く入口（`reachable_from`）、それに言及している既存テストが出る。
言及しているテストがないときは `entry_point_tests` が出る。
`reachable_from` のうち public な入口について、そのクラスを書き、入口と同じ名前のメソッドを呼んでいるテストファイルである。
`--coverage` を渡すと、grep の代わりに JSON の行リストを使う。
ブリーフの最後には、変更メソッドを持つクラスやモジュールごとに `entrypoints <Const>:` の節が出る。
その節は、そのクラスの head での public メソッドを並べる（head に無ければ base のもの）。
変更メソッドが先に変更の種類つきで並び、残りは `unchanged` として続き、最大 12 件である。
`unchanged` のうち変更メソッドに届くものが先に並び、入らなかったメソッドの数を `(+N more)` と出す。
どちらかの側で `initialize` を定義するクラスは、その代わりに `Owner.new` を `Owner#initialize` の変更の種類つきで出す。
これはテストが呼べるメソッドであり、`run` はその名前も言及として数える。

`run` はリビジョンごとに git worktree を作り、スクラッチディレクトリをその worktree の `.jitcatch/` へコピーし、ファイルごとに 1 プロセスで実行する。

```sh
ruby -Ilib -I. -r<jitcatch>/lib/jitcatch/minitest_cause.rb .jitcatch/<file> -v --seed 1
ruby -Ilib -I. -e 'require "rspec/core"; exit(RSpec::Core::Runner.run(ARGV))' -- \
  --format json --out .jitcatch-report.json --seed 1 --backtrace --no-color .jitcatch/<file>_spec.rb
```

`*_spec.rb` という名前のファイルは RSpec で実行する。
ただし `minitest` を require するファイル（minitest/spec のファイル）は Minitest で実行する。
RSpec はワークツリーの `.rspec` を読むので、そこにある `--require spec_helper` も効き、`spec/` もロードパスに入る。
コマンドラインで渡したフォーマッタが、`.rspec` にあるフォーマッタに代わる。
1 つの example が 1 行になり、行の名前はその full description（`Cart#total sums the prices`）である。
テキストの報告にはその行番号（`cart_spec.rb:11`）も出る。
期待が外れた失敗は `fail`、それ以外のエラーは `error`、`pending` は `skip` になる。
RSpec がファイルを読む途中のエラーは、Minitest と同じく `<file>#load` の 1 行になる。

リビジョンに `Gemfile` があるときは、`-rbundler/setup` を付け、`BUNDLE_GEMFILE` をその `Gemfile` にして実行する。
そのため、それぞれの側は自分のロックファイルにある gem を読む。
それぞれの側には、git が追跡しないチェックアウトの `.bundle/config`（`bundle config set --local` が書く `BUNDLE_WITHOUT` などの設定）も写す。
相対パスの `BUNDLE_PATH` は、チェックアウトのディレクトリを指したままにする。
`run` はテストを実行する前に、側ごとに 1 回、その側が bundle とテストフレームワーク（Minitest の候補なら `minitest`、RSpec の候補なら `rspec-core`）を読めるかを確かめる。
`Gemfile` が無い側では、jitcatch を動かす Ruby にフレームワークがあるかを確かめる。
成功した実行は、`Gemfile` がある側ごとに `bundle base ok` を出す。
ある側が確認に失敗すると（たとえばロックした gem がインストールされていないとき）、その側ではすべての候補が読み込みに失敗し、`fail_on_base` や回帰のように見えてしまう。
そのため `run` は終了コード 3 で止まり、失敗した側、失敗したコマンド、その stderr の最後の行を出す。

```text
jitcatch: setup failed, so no test ran; a test cannot pass or fail on a side that cannot load
base <sha>
head <sha>
setup head failed: ruby -e 'require "bundler/setup"; require "minitest"'
  Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems.
  not passed: BUNDLE_WITHOUT (add --env BUNDLE_WITHOUT)
Run that command in a checkout of that side, fix what it says (often `bundle install` there), and run jitcatch again.
```

確認に通った側でも、すべての候補が読み込むものを起動できないことがある。
たとえば、テスト用データベースが無い Rails アプリである。
すべてのファイルが両方の側でエラーになった `<file>#load` の行なら、どの行も base と head を区別できないので、`run` はやはり終了コード 3 で止まる。
そのときの最初の行は `jitcatch: every candidate file failed to load on both sides, so no row can tell base from head` で、側ごとに最初のファイルの再実行コマンドを示す `load base failed:` の行と、その下にエラーが出る。

この文は stderr に出る。
`--json` のときは、代わりに stdout に `{"command": "run", "error": "setup_failed", "stage", "base", "head", "setup_failed": [{"side", "commit", "command", "stderr", "not_passed"}]}` を出す。
`stage` は `setup` か `load` である。
`assess` はこの文書を受け付けない。
プロセスに渡す環境変数は、決まった一覧と `--env` で名前を挙げたものだけである。
失敗した側は、今の環境にあって `--env` で渡していない Bundler の設定（`BUNDLE_WITHOUT`、`BUNDLE_PATH` などの `BUNDLE_` で始まる変数）を `not passed:` の行（`--json` では `not_passed`）で名指しする。

実行されるのは `*_test.rb`、`test_*.rb`、`*_spec.rb` である。
その名前が 1 つも無いときは、すべての `.rb` を実行する。
上限は 40 ファイル。
base で通り、head で失敗、エラー、またはタイムアウトになったテストが候補になる。
`--reruns` は候補を head で繰り返す。
1 回でも結果が違えば `flaky` である。
比べるのは失敗メッセージの全体である。
比べる前に一時ディレクトリ直下の名前とオブジェクトのアドレス（`#<Class:0x00007f...>`）を伏せるので、メッセージにある `Dir.mktmpdir` のパスや新しい無名クラスは違いにならない。
再実行の行には、メッセージのうち変わった最初の行が出る。
テキストの報告は `flaky` の行の下に各再実行の結果を出し、JSON の行は `reruns` に持つ。
タイムアウトは再実行しない。

候補を `discarded` にするルールは 4 つある。
head での `LoadError`、タイムアウト、データベースが無いか届かないことを示す head での Active Record のエラー（`NoDatabaseError`、`ConnectionNotEstablished`、`DatabaseConnectionError`）、そして diff が消したかシグネチャを書き換えた名前に対する `NameError`、`NoMethodError`、引数個数の `ArgumentError` である。
消えたクラスやモジュールも消えた名前に数える。
引数個数の `ArgumentError` とは `wrong number of arguments`、`missing keyword`、`unknown keyword`、`struct size differs`（メンバーより多くの値を渡した `Struct`）のことで、`assert_raises` や RSpec の `raise_error` が受け取って失敗にしたときも同じに扱う。
コードが意図して起こす `ArgumentError`（`qty must be > 0` のようなもの）は `reported` のまま残る。

同じリポジトリと同じテストなら、出力は同じバイトになる。
順序は固定で、テキストに時刻は無い。
メッセージの中の worktree の絶対パスの根は、`{worktree}/lib/cart.rb` の中でも `Dir.pwd` だけでも `{worktree}` と書き、バックトレースのフレームからは除く。
Ruby 自身の prefix は `{ruby}/` と書く。

`assess:` の下の候補の行は、それぞれ `rerun:` の行で終わる。
`--json` のすべての行にも `rerun` がある。
これは、手元のチェックアウトでリポジトリの根からそのテスト 1 つだけを再実行するコマンドである。
`{tests}/` は渡した `TESTS_DIR` を表す。
たとえば `ruby -Ilib -I. -e 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))' {tests}/cart_spec.rb:11` や `ruby -Ilib -I. {tests}/cart_test.rb -n CartTest#test_total` で、head に `Gemfile` があれば `bundle exec` が前に付く。
`<file>#load` と `<file>#timeout` の行は、ファイル全体を再実行する。
RSpec の行がただの `rspec` でないのは、`rspec` が `spec/` を持ついちばん近い親ディレクトリの `lib/` を読み込みパスの先頭に置くからである。
そのため Rails アプリの `tmp/` の下にあるチェックアウトでは、アプリの `lib/` を読んでしまう。
この行はそのディレクトリを作業ディレクトリに固定し、実行時のワークツリーでも同じようにする。
Rails アプリのように head の根に `spec` があれば、RSpec はもともとその根を見つける。
そのときこの行は、rspec-core の内部の状態を書き換えるただ一つの部分である固定（`RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); `）を省く。
また、RSpec が表示するオブジェクトを 200 文字で切る設定を外すので、`raise_error` の行は受け取ったエラーを最後まで示す。

## Rails アプリ

Rails アプリの候補は、アプリ自身の spec と同じく `require "rails_helper"` で始まる RSpec のファイルか、`require "test/test_helper"` で始まる Minitest のファイルである。
候補はアプリのファクトリーとテスト用データベースを使える。

base と head はアプリを同時に起動する。
相対パスの SQLite（Rails の既定の `storage/test.sqlite3`）はワークツリーごとのファイルなので、2 つの側は出会わない。
PostgreSQL や MySQL のようなデータベースサーバーでは、テスト用データベースの名前が両方の側で同じで、それぞれの側がもう一方の実行中に自分の `db/schema.rb` を読み込む。
列を消す変更では、6 つの候補のうち 1 つから 6 つが、読み込みエラー（`bin/rails aborted!`）として `reported` になった。
jitcatch はチェックアウトごとに `TEST_ENV_NUMBER` を設定する。
これは parallel_tests が設定する変数である。
最初のワーカーの base と head には `1` と `2`、2 番目のワーカーには `3` と `4` を渡し、以下同じように続ける。
両方のリビジョンの `config/database.yml` がこの変数でテスト用データベースを名付けていれば、チェックアウトごとに別のデータベースを使い、同じ実行で `reported` は 0 になった。

```yaml
test:
  <<: *default
  database: app_test<%= ENV["TEST_ENV_NUMBER"] %>
```

最初の実行の前に、ワーカー 1 つにつき 2 つのデータベースを一度だけ作る。
スキーマは、Rails が起動するときにそれぞれのリビジョンのものを読み込む。

```sh
for n in 1 2; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done
```

head のデータベースが無いときは、その行は `discard:no_database` になる。
`database.yml` がこの変数を使っていないときは `--serial` を渡し、一度に 1 つのプロセスだけを動かす。
手元のサンプルアプリでは、6 つのファイルに `--serial` で 34 秒、番号付きのデータベースで 6 秒から 10 秒かかった。

それぞれのチェックアウトには、git が追跡するファイルしか無い。
認証情報を読むイニシャライザーは、`config/master.key` が無いのでそこで失敗する。
鍵は `RAILS_MASTER_KEY=$(cat config/master.key) jitcatch run --env RAILS_MASTER_KEY BASE HEAD TESTS_DIR` のように渡す。

ファイルごとに、それぞれの側でアプリを 1 回起動する。
サンプルアプリ（4 CPU）では、example が 1 つずつの 6 ファイルに 9.8 秒、同じ 6 つの example を 1 ファイルにまとめると 1.9 秒かかった。
bootsnap のキャッシュは、チェックアウトごとに空から始まる。
1 ファイルでは bootsnap ありで 3.7 秒、`--env DISABLE_BOOTSNAP` で `DISABLE_BOOTSNAP=1` を渡すと 2.5 秒だった。
6 ファイルでは bootsnap ありで 8.0 秒、なしで 9.8 秒だった。

## インストール

実行ファイルは、このリポジトリのチェックアウトにある `bin/jitcatch` である。
そのディレクトリを `PATH` に置く。

スキルは [`skills`](https://github.com/vercel-labs/skills) CLI で入れる（Node.js 22.20 以降）。
このリポジトリは非公開なので、Git の認証情報、GitHub CLI、または SSH で GitHub にアクセスできる必要がある。

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

確認を飛ばすときは `-y` を足す。
`bin/jitcatch` も `PATH` に置く。

CLI を使わない場合は、`skills/jitcatch` をエージェントの skills ディレクトリへコピーまたはシンボリックリンクする（例: `.agents/skills/`、`.claude/skills/`、`.cursor/skills/`）。

## 限界

- 呼び出しを数えるのは、レシーバのクラスがソースに書かれているときだけである。
  `self`（レシーバなしを含む）、定数（`Cart.build`）、`self.class`、それらの `new`、そしてクラスが一つの `Const.new` だけを代入するインスタンス変数がこれに当たる。
  メソッドの中のすべての代入が同じ `Const.new` であるローカル変数（`repo = Repo.new; repo.read`）もこれに当たる。
  同じクラスのメソッドが返す値への呼び出し（`emitter_for(format).render`）は、そのメソッドが定数と nil だけを返すとき（`case`、`if`、三項演算子を通して）、返しうる定数それぞれへ向かう。
  引数、ほかの値を代入したローカル変数、それ以外の戻り値への呼び出しは辺にならないので、`reachable_from` が呼び出し元を落とすことがある。
  そうした呼び出しは、送る名前が変更メソッドの名前か、その `reachable_from` にあるメソッドの名前であれば、その変更メソッドの `dynamic_callers:` に `Emit.looked_up (render)` のように出る。
  クラスが定義していないメソッドを `self` に呼ぶと、その名前を持つ索引上ただ一つのメソッドへ向かう。
  モジュールやスーパークラスのメソッドのためである。
  インスタンスメソッドからはインスタンスメソッドだけが対象になる。
  `Const.new` と、クラスメソッドの中でレシーバなしに呼ぶ `new` は、そのクラスの `initialize` へも向かう。
  クラスが定義していなければ、スーパークラスをたどって最も近い `initialize` へ向かう。
  そのため `Runner.new` の呼び出し元は `Runner#initialize` とそこから呼ぶメソッドに届く。
  `create`、`create!`、`build` も、リポジトリ内のスーパークラスの連なりが `ActiveRecord::Base` に届くクラス（`class Post < ApplicationRecord`）では同じく `initialize` へ向かう。
  Active Record はこれらを `new` を呼ぶメソッドとして定義しているからである。
  ほかのクラスでは、定義しているコードが索引にないので辺にならない。
  連なりの上に同じ名前のクラスメソッドがあれば、呼び出しはそちらへ向かう。
  クラスが `attr_reader`、`attr_writer`、`attr_accessor` で宣言した名前は、その読み書きのメソッドへの辺になる。
- `define_method` と `class_eval` は索引しない。
  `def self.foo` 以外のレシーバ付き定義は粗い。
- リネームは削除と追加に見える（`git diff --no-renames`）。
- カバレッジは集めない。
  `--coverage` は渡された JSON を読むだけである。
- 破棄ルールは、intended と regression を分けない。
- 候補テストが古い振る舞いを書いていなければ、その穴にある回帰は `reported` が 0 のままである。
- 新機能のテストは base で落ち、候補にならない。
- 関連 id は、失敗の原因の行から一段ずれていることがある。
- 言及は、そのテストメソッドと、それが直接または間接に呼ぶ同じファイルのメソッドの中にある、メソッド呼び出し、定数、シンボルである。
  `Owner.new` は、名前が `Owner` で終わるクラスの `initialize` への言及になり、`mentions` にはテストが書いたとおりに出る。
  `A::Owner.new` は、名前が `A::Owner` で終わるクラスだけを指すので、`B::Owner#initialize` を指さない。
  テストが名前を書いたクラスか、`.new` で作ったそのインスタンスに送る呼び出しは、`Index.parse` や `Cart#total` のようにそのクラスと一緒にも出る。
  同じ名前の変更メソッドが複数あるとき、関連 id はそのクラス(または名前がそれで終わるクラス)のものになる。
  スーパークラスが定義するメソッドのように、そのクラスに該当するものがなければ、全部を残す。
  文字列とコメントの中の語は言及にならない。
  ただし、`send`、`public_send`、`method`、`respond_to?` に普通の文字列で渡したメソッド名は、`send("total")` のように言及になる。
  `snap[:total]`、`snap.fetch(:total)`、`{ total: 1 }` のようにハッシュのキーとして使ったシンボルは言及にならない。
  `message`、`full_message`、`detailed_message` の呼び出しは、`to_s` への言及にもなる。
  エラークラスは、メッセージを作るために `to_s` を上書きするからである。
  `"exe/tool"` や `"../bin/x"` のような相対パスの形の文字列が head のファイルを指すときは、テストが別のプロセスで起動するスクリプトとみなし、そのファイルの中の名前も言及になる。
  パスは、リポジトリの根から、候補のディレクトリから、または候補の隣で `File.expand_path` が読むとおりに読む。
  別のファイルのヘルパーは読まない。
- `--workers` を渡さなければ、ファイルは 1 つずつ実行する。
  1 つのファイルの base 側と head 側は、それぞれの worktree で同時に走る。
  そのため、worktree の外の決まったパスに書くテストや、決まったポートで待ち受けるテストは、もう一方の側とぶつかることがある。
  `--workers` を渡すと、ほかのファイルともぶつかることがある。
  そのようなファイルには `--serial` を渡す。
  リポジトリの既存スイートは走らない。
  worktree を追加できる git リポジトリが要る。
- アサーションのバックトレースはテストの中で止まりがちなので、ライブラリの行はテストが言及した名前から探す。
- RSpec の example の言及は、その example のブロック、それを囲むグループの `let`、`subject`、フックのブロック、それらのグループの引数、そしてそれらが呼ぶ同じファイルのヘルパーから取る。
  `"#total"` や `".build"` と記述したグループは、そのメソッドを指す。
  `described_class.new` は `Owner.new` を指す。
  `described_class.parse` は `Owner.parse` として出る。
  `let(:result)` や `subject(:result)` の名前は spec 自身のヘルパーなので、その名前も、レシーバのない `result` の呼び出しも、変更メソッド `result` への言及にならない。
  そのブロックが一つのクラスを作るときは、`let(:cart) { Cart.new }` のように、`cart.total` は `Cart#total` として出る。
  暗黙の `subject`、共有 example グループ、`spec/support` のヘルパーは読まない。
  別のファイルで定義した共有グループの example は、候補ファイル全体を読む。
- データベースサーバーを使う Rails アプリの base と head は、両方のリビジョンの `config/database.yml` が `TEST_ENV_NUMBER` でテスト用データベースを名付けていない限り、1 つのテスト用データベースを共有する（Rails アプリの節を参照）。
  テストスイートが試すのは Rails プロジェクトの形だけである。
  Rails の手順は、PostgreSQL 16 と SQLite を使う Rails 8.1 のアプリで測った。
- RSpec のすべての example の外で起きたエラー（`after(:suite)` フックの中など）は、example が 1 つも走らなかったときだけ報告する。

## 開発

```sh
ruby -Ilib test/run.rb
```

エンジンテストは一時 git リポジトリを作り、context、実行、フレーク、タイムアウト、シグネチャ変更の破棄を見る。
`test/jitcatch/test_shop_demo.rb` はショップのフィクスチャを作り直し、`context` と `run` を `examples/runs/*/context.txt` および `run.txt` とバイト単位で比べる。

## ライセンス

MIT
