# jitcatch

jitcatch は、変更の親で通り、その変更で落ちる Ruby のテストを残し、それぞれが届く変更されたメソッドを示す。

## Rails アプリでのクイックスタート

Ruby 3.3 以降、git、そして spec を RSpec（`rspec-rails`）で走らせるアプリが要る。
どの手順もアプリのルートで走らせる。

### 1. gem を足す

アプリの `Gemfile` の `:development, :test` グループに jitcatch を足し、`bundle install` を走らせる。
jitcatch には実行時の依存がないので、bundle にほかの gem は増えない。

<!-- rails:gemfile -->
```ruby
group :development, :test do
  gem "jitcatch", require: false
end
```

Rails の既定の場所にある SQLite なら、準備は要らない。
テスト用データベースが 1 つの名前の PostgreSQL や MySQL なら、jitcatch は base と head がそれを共有すると見つけ、プロセスを 1 つずつ動かす。
そのとき `warning:` が、両側を同時に動かすために `config/database.yml` のどこを変えるかを示す。
詳しくは [Rails アプリ](#rails-アプリ) を参照。

### 2. コミットを選ぶ

最初の対象には、分岐がいくつかあり既存の spec もあるモデルのメソッドを変えた、最近のコミットが向いている。
モデルを変えた最近のコミットを並べる。

<!-- rails:pick -->
```sh
git log --oneline -n 5 -- app/models
```

### 3. spec を 1 つ書いて jitcatch を走らせる

そのコミットの前にメソッドが何をしていたかを述べる spec を 1 つ書く。
置き場所は git が無視する `tmp/jitcatch` にし、`require "rails_helper"` で始め、アプリ自身の spec と同じようにファクトリを使う。
そのあと、そのコミットに対して jitcatch を走らせる。
`Loan`、`approve`、期待する結果、`72ebf7a` は、自分のモデル、そのメソッド、コミットの前にメソッドが返していた値、選んだコミットに置き換える。

<!-- rails:script -->
```sh
mkdir -p tmp/jitcatch
cat > tmp/jitcatch/loan_approve_spec.rb <<'RUBY'
require "rails_helper"

RSpec.describe Loan, type: :model do
  it "lets a clerk approve a loan of 10000 cents" do
    loan = create(:loan, amount_cents: 10_000)
    expect(loan.approve(name: "Grace", senior: false)).to eq(:approved)
  end
end
RUBY
bundle exec jitcatch run 72ebf7a~1 72ebf7a tmp/jitcatch
```

## 表示される内容

次の出力は小さなサンプルアプリでのものである。
FactoryBot と SQLite を使う Rails 8.1 アプリで、`Loan#approve` は大きな貸付の承認をシニアの担当者に求める。
`git log` は 2 つのコミットを並べる。

<!-- rails:pick-output -->
```
72ebf7a Ask a senior officer from 10000 cents.
4a1d57a Characterize Loan#approve.
```

最後のコミットは、10000 セントを超えるときだけでなく、10000 セントちょうどからシニアの担当者を求めるようにした。
jitcatch は次を出す。

<!-- rails:output -->
```
jitcatch run
version 0.1.0
base 4a1d57ae042c0b5dd0ae5b1c14f5623c9b2ec302
head 72ebf7ab5ce5a144c85d971160c207e2582d8f5b
reruns 2
timeout_s 60
bundle base ok
bundle head ok
tests:
  t01 reported Loan lets a clerk approve a loan of 10000 cents loan_approve_spec.rb:4 m01
counts generated=1 no_signal=0 fail_on_base=0 candidates=1 flaky=0 discarded=0 reported=1
assess:
  c01 Loan lets a clerk approve a loan of 10000 cents base=pass head=fail m01 assertion,report,touches:changed_method
    expected: :approved
    got: :needs_senior
    rerun: bundle exec rspec -I. -r jitcatch/rspec tmp/jitcatch/loan_approve_spec.rb:4
```

spec は親で通り、そのコミットで落ちるので、`reported` になる。
コミットが古いコードの振る舞いを変えたということである。
`expected:` は古い結果で、`got:` は新しい結果である。
`m01` は spec が届く変更されたメソッド、`Loan#approve` である。
次にコミットメッセージを読む。
このメッセージはその変更を求めているので、この行は意図どおりである。
その一文がなければ、回帰の疑いが強い。
`rerun:` の行を走らせると、その失敗をもう一度見られる。
`bundle exec jitcatch context 72ebf7a~1 72ebf7a` を走らせると、変更されたメソッドごとに古いソースと新しいソースを見られる。
親でも落ちる spec は新しい振る舞いを書いたものなので、`fail_on_base` になり、証拠にはならない。
jitcatch は両側の新しいチェックアウトでアプリを起動し、そこで spec ファイルごとに最大 60 秒待つ。
行がタイムアウトしたら、その `hint:` の行が、何を渡すか何を上げるかを示す。

## アプリなしで試す

Ruby 3.3 以降と git が要る。

```sh
gem install jitcatch
```

空のフォルダで、次をシェルに貼り付ける。
2 つのコミットを持つ git リポジトリができる。
2 つ目のコミットは空の注文の送料をなくすためのものだが、ちょうど 50 の注文の送料無料もなくしてしまう。
そのあと候補のテストを 3 つ書き、jitcatch を走らせる。

<!-- quickstart:script -->
```sh
mkdir jitcatch-demo && cd jitcatch-demo && git init -q

mkdir lib && cat > lib/shipping.rb <<'RUBY'
module Shipping
  # Orders of 50 dollars or more ship free.
  def self.fee(total)
    total >= 50 ? 0 : 5
  end
end
RUBY
git add . && git commit -qm "Add the shipping fee" && git tag base

cat > lib/shipping.rb <<'RUBY'
module Shipping
  # Orders of 50 dollars or more ship free.
  def self.fee(total)
    return 0 if total.zero?

    total > 50 ? 0 : 5
  end
end
RUBY
git commit -qam "Charge no fee on an empty order"

mkdir candidates && cat > candidates/shipping_test.rb <<'RUBY'
require "minitest/autorun"
require "shipping"

class ShippingTest < Minitest::Test
  def test_fifty_ships_free
    assert_equal 0, Shipping.fee(50)
  end

  def test_empty_order_has_no_fee
    assert_equal 0, Shipping.fee(0)
  end

  def test_small_order_pays_five
    assert_equal 5, Shipping.fee(10)
  end
end
RUBY

jitcatch run base HEAD candidates
```

jitcatch は次を出す。
2 つのコミット ID は手元のものになる。

<!-- quickstart:output -->
```
jitcatch run
version 0.1.0
base 81b05b22f14f2b5a1e580c048856a5e9d9b25b85
head 7c53dd7485d4c994d97bddd3cb7bd5481a337b61
reruns 2
timeout_s 10
tests:
  t01 fail_on_base ShippingTest#test_empty_order_has_no_fee shipping_test.rb
    base: fail Minitest::Assertion Expected: 0
      Actual: 5
  t02 reported ShippingTest#test_fifty_ships_free shipping_test.rb m01
  t03 no_signal ShippingTest#test_small_order_pays_five shipping_test.rb
counts generated=3 no_signal=1 fail_on_base=1 candidates=1 flaky=0 discarded=0 reported=1
assess:
  c01 ShippingTest#test_fifty_ships_free base=pass head=fail m01 assertion,report,touches:changed_method
    Expected: 0
    Actual: 5
    rerun: ruby -Ilib -I. candidates/shipping_test.rb -n ShippingTest#test_fifty_ships_free
```

`test_fifty_ships_free` は親で通り、変更で落ちるので、`reported` になる。
古いコードが満たしていた主張を、変更が壊したということである。
`test_empty_order_has_no_fee` は新しい振る舞いを書いたもので、親で落ちるので `fail_on_base` になり、証拠にはならない。
`test_small_order_pays_five` は両側で通る。
コミットメッセージが求めているのは空の注文の規則だけなので、報告された行は回帰の疑いが強い。
`rerun:` の行を走らせると、その失敗をもう一度見られる。
比較を直すか、意図のほうを変える。

`m01` は、報告されたテストが届く変更されたメソッドである。
`jitcatch context base HEAD` は意図を出し、変更されたメソッドごとに、古いソースと新しいソースを含むブロックを出す。

<!-- quickstart:context -->
```
methods:
  [m01] modified Shipping.fee lib/shipping.rb:3-7 signature=same visibility=public
    callsites: (none)
    tests: (none)
    old:
      def self.fee(total)
        total >= 50 ? 0 : 5
      end
    new:
      def self.fee(total)
        return 0 if total.zero?
      
        total > 50 ? 0 : 5
      end
```

## 使い方

変更をレビューするエージェントは、その差分向けのテストを書く。
新しい振る舞いだけを書いたテストは親で落ち、回帰の証拠にならない。
親がすでに満たしていて変更後に落ちるテストは、古いコードが満たしていた主張を新しいコードが壊したことを示す。
jitcatch はそのテストを両方のリビジョンで走らせ、フレークと、ほかのいくつかの非シグナルを除いて、残ったものを出す。

方法は Meta の catching JiT tests に沿う（[Harden and Catch](https://arxiv.org/abs/2504.16472)、Meta での報告は [Just-in-Time Catching Test Generation at Meta](https://arxiv.org/abs/2601.22832)）。

Ruby 3.3 以降。
追加の gem はない。
`minitest` と `prism` は Ruby に付いている。
`jitcatch --version`（または `-v`）は `jitcatch 0.1.0` を出し、`--help` はコマンドの一覧を出す。
git から入れた gem のように jitcatch 自身の git のチェックアウトから動くときは、`jitcatch 0.1.0 (1fbcd18)` のようにコミットも出す。
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
| `--timeout SEC` | `run` | テストファイルを止めるまでの秒数。head に `config/application.rb` があれば既定は 60 で、それ以外は 10。Rails アプリは新しいチェックアウトごとに起動して `db/schema.rb` を読み込むからである。最小は 1。 |
| `--workers N` | `run` | 同時に実行するテストファイルの数。ワーカーごとに base と head の worktree を持つ。既定は 1。1 つのワーカーは Ruby プロセスを 2 つ同時に動かすので、ワーカーを増やして速くなるのは CPU が空いているときだけである。N によらずレポートは同じになる。 |
| `--serial` | `run` | Ruby プロセスを 1 つずつ動かす。ファイルの base 側を走らせてから head 側を走らせる。worktree の外の決まったパスに書く候補や、決まったポートで待ち受ける候補のためのものである。`--workers` に 1 より大きい値は渡せない。Rails アプリの base と head が 1 つのテスト用データベースを共有するときも、`run` は `warning:` を出してこのように動かす（Rails アプリの節を参照）。テキストのレポートは `serial` と出し、`--json` は `"serial": true` を記録する。 |
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
Minitest は出力しないので、jitcatch は Minitest の候補の各プロセスに `-r` で `lib/jitcatch/minitest_report.rb` を読み込み、Minitest のエラーの文に元のエラーを足す。
`rerun:` の行はこれを読み込まない。
行の 1 行が 300 文字を超えると、`FrozenError` に出た凍結 Array 全体のような行でも、最初と最後の 150 文字を残し、そのあいだを `... (+N characters; the whole message is in --json) ...` にする。
マッチャーが受け取ったエラーでは、長いパスのあとの末尾に違いがあることが多いからである。
その行が、下に RSpec の `Diff:` を持つメッセージの最初の行なら、行はその diff で消えた行と加わった行（最大 8 行）を足す。
`have_attributes` はレコードと両方の属性の Hash を 1 行に出すので、`-:state => "pending",` と `+:state => "draft",` のように違う属性がこれで見える。
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
| 3 | `run` は何もテストしなかった。ある側がセットアップの確認に失敗したか、どちらの側でも候補ファイルが 1 つも読み込めなかったか、すべての行がある側でタイムアウトしたかデータベースが見つからなかった。 |

### 結果

| 区分 | 意味 |
| --- | --- |
| `no_signal` | base でも head でも通った。 |
| `fail_on_base` | 親がそのテストを満たさなかった。新しい機能だけを書いていることが多い。テキストの報告は、その行の下に base で起きたことを `base: error NoMethodError undefined method 'apply_coupon' for an instance of Shop::Cart` のように出す。 |
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
テストが変更されていない呼び出し元を通してだけ届くメソッドの中では、テストが名指しする入口から最も多くの呼び出しを下ったメソッドを選ぶ。
たとえば、リクエストスペックが 1 回下の `LoansController#officer` と 5 回下の `Borrower#approved_cents` に届くときは `Borrower#approved_cents` を選ぶ。
`--json` の `caller_depths` がその回数を持つ。
上位の二つを id でしか並べられないときは、どれも選ばない。
その行は `related guess: none of m01,m02,m03` となり、id の位置に `-` が出て、`method_id` は `null` になる。
この行には、テストが `method_ids` のどれか一つの名前を含めば `touches:changed_method` を付ける。
id が最も小さいものだけを見るのではない。
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
定数も同じで、別のファイルへ移って値が同じなら `moved` になり、`moved_from=` が付き、その定数を読むメソッドは `affected` にならない。
移るときに値も変わった定数は、`moved_from=` 付きの `modified` になる。
`attr_reader`、`attr_writer`、`attr_accessor`、`Struct.new` や `Data.define` のメンバーが定義する読み書きのメソッドもメソッドとして数え、ソースには名前一つの形（`attr_reader :seed`）が出る。
そのため、その行から外した名前は `removed` になり、行に残った名前は変わらない。
`*FIELDS` の形で渡したリストも、同じファイルがその前に `FIELDS = %i[x y].freeze` のようにシンボルのリストを入れていれば数える。
このとき各メンバーは、そのリストの中の自分のシンボルの行を持つ。
クラス本体の条件分岐の中にある `def` や読み出しメソッド（`attr_reader :x if cond`）も数える。
分岐はすべてが順に走ったものとして読むので、分岐の中の引数のない `private` は条件分岐の後にも効く。
Concern の `included do`、`prepended do`、`class_methods do` ブロックの中にあるものも数える。
片方の側にしか無いクラスやモジュールも定数として `added` か `removed` になり、ソースには宣言の行が出る。
各メソッドには、旧ソースと新ソース、ライブラリ内の呼び出し、そこへ届く入口（`reachable_from`）、それに言及している既存テストが出る。
変更された `initialize` には `built_by:` も出る。
これは `new` のほかにそれを走らせる呼び出しで、Active Record のモデルの `create`、`create!`、`build` と、そのクラスを作る FactoryBot のファクトリーごとの `build(:loan)` と `create(:loan)` である。
その `tests:` には、そのどれかか `Owner.new` を呼ぶテストファイルが、呼んでいるもの（`spec/models/loan_spec.rb via create(:loan)`）と一緒に出る。
テストが `initialize` をその名前で呼ぶことはないので、コンストラクタには grep の結果を出さない。
ファクトリーは `spec/factories` と `test/factories` から、読み込まずにソースとして読む。
クラスはまず `class:`（定数、文字列、シンボル）から、次に親（`parent:` か、入れ子の外側のファクトリー）から、最後に名前を camelize したものから決まり、`aliases:` の別名も同じクラスを作る。
ファクトリーは、その関連が作るクラスにも数える。
関連とは、ファクトリーの名前と同じ素の `borrower`、`association :borrower`（`factory: :user` も）、`association` を呼ぶ属性ブロックで、そのファクトリーか継承元に書いたもののことで、関連の関連もたどる。
そのため `create(:loan)` は `Borrower` も保存する。
trait の中の関連は、その trait を名指しする呼び出しにだけ数える。
`:loan` の trait `:cosigned` が cosigner を作るなら、`create(:loan)` ではなく `create(:loan, :cosigned)` と `build(:loan, :cosigned)` が加わる。
`create(:loan, :cosigned, amount_cents: 5)` と書いたテストは、`create(:loan)` と `create(:loan, :cosigned)` の両方を挙げる。
ファクトリーは親と入れ子の外側のファクトリーの trait も使う。
ファクトリーの外で定義した trait と、別の trait を含む trait はたどらない。
ソースからクラスが決まらないファクトリーはたどらず、理由と一緒に `factories_skipped:` に出す。
実行時に計算する `class:`、そこで読んだファクトリーにない親、どのファイルも定義しないクラスがこれに当たり、最後のものはアプリが設定する活用（`ApiKey` と `APIKey`）で起こりうる。
Active Record のモデルのクラス本体がコールバックかバリデーション（`after_save :count_save`、`validate :check`、またはそのどちらかの `if:` や `unless:`。`validates :amount, presence: true, if: :checked?` もこれに当たる）で名前を挙げるメソッドには `run_by:` が出る。
これは Rails の規則でそのメソッドを走らせる呼び出しで、後ろに名前を挙げた行が続く。
save のコールバックには `Loan.create`、`Loan.create!`、`Loan#save`、`Loan#save!`、`Loan#update`、`Loan#update!` と、そのクラスのファクトリーごとの `create(:loan)` と `build(:loan)` が出る（create のコールバックには update が、update のコールバックには create が出ない）。
バリデーションにはさらに `Loan#valid?`、`Loan#invalid?`、`Loan#validate`、`Loan#validate!` が出る。
バリデーションか、commit や rollback のコールバックに `on:` があるときは、その文脈の呼び出しだけを残し、行にもその `on:` を出す。
`before_validation :mark_pending, on: :create` には update が出ないので、`update!` を呼ぶメソッドはそこへ届かない。
`on: :update` には create もファクトリーも出ない。
アプリ独自の文脈（`on: :publish`）は文脈を受け取る呼び出しからしか走らないので、`Loan#save`、`Loan#save!` と四つのバリデーションの呼び出しが出る。
シンボルで書いていない `on:` は何も絞らない。
destroy のコールバックには `Loan#destroy` と `Loan#destroy!` が出る。
そのようなコールバックから届くメソッド（`reachable_from`）にも同じ行が出る。
テスト以外のメソッドがソースに書いた形でその呼び出しをするとき（`LoanDesk.open` の中の `Loan.create!` や、`Loan` のメソッドの中の `update!`）、そのメソッドとその呼び出し元が `reachable_from` に加わる。
そのため `LoanDesk.open` を呼ぶテストはそのコールバックを指す。
引数のように、ソースが型を決めないローカル変数やインスタンス変数への呼び出しは、Rails がその名前から決めるモデルへの呼び出しとして読む。
そのため `Teller#renew(loan)` の中の `loan.save!` は `Loan` の save のコールバックに届き、`record.save!` はどれにも届かない。
その `tests:` には、grep の結果に加えて、そのどれかを呼ぶテストファイルが出る（`spec/models/loan_spec.rb via Loan.create!`）。
`run` はその呼び出しをそのメソッドへの言及として数える。
`Loan#save` は、テストのソースからレコードのクラスが決まるとき（`loan = Loan.new`）に数える。
`build(:loan)` は保存しないので、コールバックが挙げるレコードへの呼び出しも同じテストがするとき（`build(:loan).save!` や、`valid?` を呼ぶ `expect(build(:loan)).to be_valid`）にだけ数える。
作ったレコードはソースが型を決めないローカル変数に入るので、その呼び出しのレシーバーは確かめない。
そのため `build(:loan)` の隣で別のレコードを保存するテストも数える。
作るだけのテストは `tests:` にも `run` の言及にも出ない。
Concern の中のコールバックの行、親クラスが宣言するもの、サブクラスへの呼び出しはたどらない。
言及しているテストがないときは `entry_point_tests` が出る。
`reachable_from` のうち public な入口について、そのクラスを書き、入口と同じ名前のメソッドを呼んでいるテストファイルである。
`--coverage` を渡すと、grep の代わりに JSON の行リストを使う。
ブリーフの最後には、変更メソッドを持つクラスやモジュールごとに `entrypoints <Const>:` の節が出る。
その節は、そのクラスの head での public メソッドを並べる（head に無ければ base のもの）。
変更メソッドが先に変更の種類つきで並び、残りは `unchanged` として続き、最大 12 件である。
`unchanged` のうち変更メソッドに届くものが先に並び、入らなかったメソッドの数を `(+N more)` と出す。
どちらかの側で `initialize` を定義するクラスは、その代わりに `Owner.new` を `Owner#initialize` の変更の種類つきで出す。
ただし、クラスが `new` を private にしている（`private_class_method :new`、または `class << self` の中の `private :new`）ときは出さない。
これはテストが呼べるメソッドであり、`run` はその名前も言及として数える。

`run` はリビジョンごとに git worktree を作り、スクラッチディレクトリをその worktree の `.jitcatch/` へコピーし、ファイルごとに 1 プロセスで実行する。

```sh
ruby -Ilib -I. -r<jitcatch>/lib/jitcatch/minitest_report.rb .jitcatch/<file> --seed 1
ruby -Ilib -I. -e 'require "rspec/core"; exit(RSpec::Core::Runner.run(ARGV))' -- \
  --format json --out .jitcatch-report.json --seed 1 --backtrace --no-color .jitcatch/<file>_spec.rb
```

このファイルは Minitest の結果を 1 つずつ `.jitcatch-report.json` に書き、行の名前と状態は Minitest の出力ではなくそこから取る。
そのため、テストが何を出力しても、テストが同時に走っても（`parallelize_me!`）、1 つの行は 1 つのテストを指す。

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
そのため `run` は終了コード 3 で止まり、確認を動かした Ruby（バージョンとパス）、失敗した側、失敗したコマンド、その stderr の最後の行を出す。

```text
jitcatch: setup failed, so no test ran; a test cannot pass or fail on a side that cannot load
base <sha>
head <sha>
ruby 3.3.6 /opt/rbenv/versions/3.3.6/bin/ruby
setup head failed: ruby -e 'require "bundler/setup"; require "minitest"'
  Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems.
  not passed: BUNDLE_WITHOUT (add --env BUNDLE_WITHOUT)
Run that command with that Ruby in a checkout of that side, fix what it says (often `bundle install` there; a bundle installed for another Ruby reads as gems not installed), and run jitcatch again.
```

確認に通った側でも、すべての候補が読み込むものを起動できないことがある。
たとえば、テスト用データベースが無い Rails アプリである。
すべてのファイルが両方の側でエラーになった `<file>#load` の行なら、どの行も base と head を区別できないので、`run` はやはり終了コード 3 で止まる。
そのときの最初の行は `jitcatch: every candidate file failed to load on both sides, so no row can tell base from head` で、側ごとに最初のファイルの再実行コマンドを示す `load base failed:` の行と、その下にエラーが出る。

この文は、終了コード 3 の報告がどれもそうであるように stdout に出て、stderr には何も出ない。
`--json` のときは、代わりに stdout に `{"command": "run", "error": "setup_failed", "stage", "rails_app", "ruby": {"version", "path"}, "base", "head", "setup_failed": [{"side", "commit", "command", "stderr", "not_passed"}]}` を出す。
`stage` は `setup` か `load` である。
`rails_app` は head に `config/application.rb` があるときに true になる。
そのときだけ、`load` の報告に `config/master.key` と `RAILS_MASTER_KEY` の助言を足す。
`assess` はこの文書を受け付けない。
失敗した側は、今の環境にあって `--env` で渡していない Bundler の設定（`BUNDLE_WITHOUT`、`BUNDLE_PATH` などの `BUNDLE_` で始まる変数）を `not passed:` の行（`--json` では `not_passed`）で名指しする。

どの行も変更について何も言えないまま、行を出して終わる `run` もある。
すべての行が、ある側でタイムアウトしたか、ある側でデータベースが見つからなかった（base か head での `NoDatabaseError`、`ConnectionNotEstablished`、`DatabaseConnectionError`）場合である。
このような `run` は何もテストしていないので、やはり終了コード 3 で終わり、指摘の無い変更のようには読めない。
テキストは `jitcatch: no row ran to a result on both sides (6 of 6 timed out), so this run cannot tell base from head` の行で始まり、そのあとにいつもの報告が続くので、各行のヒントも残る。
括弧の中は、行に現れた原因だけを `timed out`、`found no database`、`timed out or found no database` のどれかで示す。
`--json` はいつもの run の文書を出し、その `untested` は、どの run でもそのような行の数を数える。
終了コード 3 は、`untested` が行の数と等しいことを意味する。

テストのプロセスは決まった環境変数と `--env` で名指しした変数だけを受け取るので、シェルにある名前が無いために、届かないコマンドやネットワークを待ち続けることがある。
ある行がタイムアウトすると、その行の `hint:` が、`--timeout` を延ばすよう言う前に、今の環境にあり、`--env` で渡しておらず、子プロセスが必要としそうな変数を名指しする。
それはネットワークの設定（大文字でも小文字でも `HTTPS_PROXY`、`NO_PROXY`、`ALL_PROXY`、`HTTP_PROXY`、そして `SSL_CERT_FILE`、`SSL_CERT_DIR`、`NODE_EXTRA_CA_CERTS`）か、head の Ruby ファイルか候補がリテラルで読む名前（`ENV["QUINT"]`、`ENV.fetch("QUINT")`、`ENV.key?("QUINT")`）である。
ネットワークの設定を名指しするのは、head の Ruby ファイルか候補が HTTP クライアント（`net/http`、`open-uri`、`faraday`、`httparty`、`excon`、`http`、`httpx`、`httpclient`、`rest-client`、`typhoeus`）を require するか、head の `Gemfile.lock` にそのどれかがあるか、その中の文字列、バッククォート、引数の並びがネットワークから取ってくるコマンドで始まるときだけである。
そのコマンドは `"npx `、`"npm `、`"curl `、`"wget `、そして `bundle`、`gem`、`git` のあとに `install`、`update`、`clone`、`fetch`、`pull` が続くもの（`system("bundle", "install")` など）である。
スクリプトファイルが走らせるコマンドは見ない。
そのため、ローカルの SQLite だけを使うアプリのスペックでは名指ししない。
たとえば `hint: base and head timed out after 10s; jitcatch did not pass HTTPS_PROXY QUINT, so add --env HTTPS_PROXY --env QUINT if the file needs them, then raise --timeout if it needs longer` となる。
そのような名前が無ければ、ヒントは `hint: head timed out after 10s; raise --timeout if the file needs longer` である。
head に `config/application.rb` があるときだけ、ヒントの最後に `, as a Rails app's first run in a new checkout can (it loads db/schema.rb)` が付く。
`--json` では名前が `env_not_passed` に並び、タイムアウトした行が無ければ空である。
`rails_app` は、head に `config/application.rb` があるとき true になる。

実行されるのは `*_test.rb`、`test_*.rb`、`*_spec.rb` である。
その名前が 1 つも無いときは、すべての `.rb` を実行する。
上限は 40 ファイル。
base で通り、head で失敗、エラー、またはタイムアウトになったテストが候補になる。
base でタイムアウトし、head で通らなかったテストも候補になる。
base は時間があれば通ったかもしれないので、後で述べるタイムアウトのルールがそれを除く。
`--reruns` は候補を head で繰り返す。
1 回でも結果が違えば `flaky` である。
比べるのは失敗メッセージの全体である。
比べる前に一時ディレクトリ直下の名前、オブジェクトのアドレス（`#<Class:0x00007f...>`）、日付つきの時刻（`created_at: "2026-11-04 19:02:03.212197000 +0000"`）を伏せるので、メッセージにある `Dir.mktmpdir` のパス、新しい無名クラス、レコードを保存した時刻は違いにならない。
日付だけなら伏せない。
再実行の行には、メッセージのうち変わった最初の行が出る。
テキストの報告は `flaky` の行の下に各再実行の結果を出し、JSON の行は `reruns` に持つ。
タイムアウトは再実行しない。

候補を `discarded` にするルールは 4 つある。
head での `LoadError`、どちらかの側でのタイムアウト、データベースが無いか届かないことを示す head での Active Record のエラー（`NoDatabaseError`、`ConnectionNotEstablished`、`DatabaseConnectionError`）、そして diff が消したかシグネチャを書き換えた名前に対する `NameError`、`NoMethodError`、引数個数の `ArgumentError` である。
消えたクラスやモジュールも消えた名前に数える。
引数個数の `ArgumentError` とは `wrong number of arguments`、`missing keyword`、`unknown keyword`、`struct size differs`（メンバーより多くの値を渡した `Struct`）のことで、`assert_raises` や RSpec の `raise_error` が受け取って失敗にしたときも同じに扱う。
コードが意図して起こす `ArgumentError`（`qty must be > 0` のようなもの）は `reported` のまま残る。

同じリポジトリと同じテストなら、出力は同じバイトになる。
順序は固定で、テキストに時刻は無い。
メッセージの中の worktree の絶対パスの根は、`{worktree}/lib/cart.rb` の中でも `Dir.pwd` だけでも `{worktree}` と書き、バックトレースのフレームからは除く。
メッセージが `{worktree}/.jitcatch` のコピーを指すところは、`rerun:` の行と同じくテストのディレクトリを指すように書き換える。
リポジトリの中の `TESTS_DIR` `candidates/` なら `{worktree}/candidates/fixtures/a.json` と書き、リポジトリの外の `../catch/tests` なら `{worktree}/../catch/tests/fixtures/a.json` と書く。
テストの中のバックトレースのフレームも、`{worktree}/` を付けずに同じように `TESTS_DIR` を書く（`candidates/cart_test.rb` や `../catch/tests/cart_test.rb`）。
`run` の `--json` はそのパスを `tests_dir` に書き、`assess` はその下のフレームをテスト自身のものとして読む。
`__FILE__` のような相対の `.jitcatch/` はそのまま残す。
テストが比べる文字列と見分けられないからである。
ただし、読み込めなかったファイルについて Ruby が出すエラー報告の行頭の `.jitcatch/x_test.rb:2:in` は、`rerun:` の行と同じく `TESTS_DIR` の下の名前に書き換える。
`TESTS_DIR` を絶対パスで書くときは、`{worktree}/` を付けない。
Ruby 自身の prefix は `{ruby}/` と書く。

`assess:` の下の候補の行は、それぞれ `rerun:` の行で終わる。
`--json` のすべての行にも `rerun` がある。
これは、手元のチェックアウトでリポジトリの根からそのテスト 1 つだけを再実行するコマンドである。
候補のパスは、リポジトリのルートから届く形で書く。
`TESTS_DIR` がリポジトリの外にあっても、ルートからのパス（`../catch/tests/cart_test.rb`）になる。
そのため、出たとおりに実行でき、この行はどの手元のディレクトリも含まない。
ただし、ホームディレクトリの奥のチェックアウトから `/tmp` の下のディレクトリへのように、ルートからのパスが絶対パスより長くなるときは、この行と `require_relative` の警告は絶対パス（`/tmp/catch/cart_test.rb`）を出す。
`run` は各チェックアウトのルートに置いた `TESTS_DIR` の写しから候補を読み込む。
そのため、`TESTS_DIR` の外へ出る `require_relative` は、実行ではチェックアウトのファイルを指し、この行からは `TESTS_DIR` の隣のファイルを指す。
`TESTS_DIR` がルートの直下にない限り二つは食い違うので、そのとき `run` はその行と二つのファイルを `warning:` に出す（`a_test.rb:2 require_relative "../lib/a" loads lib/a.rb in the run but ../base/lib/a.rb from the rerun line`）。
メソッドやブロックの中の `require_relative` も数え、文字列リテラルの `File.join` はそれがつなぐパスとして読む。
`File.join(__dir__, "helper")` や式展開を含む文字列のように、ソースからパスが決まらないものは、`TESTS_DIR` がルートの直下にない限り、二つが同じファイルを読み込むかを jitcatch が確かめられないと `warning:` に出す。
リポジトリのコードは `require` とこの行の `-I` で読み込む。
この行はシェルで実行し、`--env` で渡した変数はそのシェルから来ているので、この行にも届く。
行には値を書かない。
たとえば `ruby -Ilib -I. -e 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))' candidates/cart_spec.rb:11` や `ruby -Ilib -I. candidates/cart_test.rb -n CartTest#test_total` で、head に `Gemfile` があれば `bundle exec` が前に付く。
`<file>#load` と `<file>#timeout` の行は、ファイル全体を再実行する。
Rails アプリのように head の根に `spec` があり、jitcatch を実行したチェックアウトが `jitcatch/rspec` を読み込めるとき、RSpec の行は `rspec -I. -r jitcatch/rspec candidates/cart_spec.rb:11` になる。
チェックアウトが読み込めるのは、クイックスタートのようにその `Gemfile` が jitcatch を挙げるとき、または `Gemfile` がなく、使っている Ruby に gem が入っているときである。
`jitcatch/rspec` は RSpec が表示するオブジェクトを 200 文字で切る設定を外すので、`raise_error` の行は受け取ったエラーを最後まで示す。
それ以外のとき、この行は上の例のように、実行と同じ起動のしかたで Ruby を動かし、これも切る設定を外す。
その起動がただの `rspec` でないのは、`rspec` が `spec/` を持ついちばん近い親ディレクトリの `lib/` を読み込みパスの先頭に置くからである。
そのため Rails アプリの `tmp/` の下にあるチェックアウトでは、アプリの `lib/` を読んでしまう。
この起動はそのディレクトリを作業ディレクトリに固定し、実行時のワークツリーでも同じようにする。
head の根に `spec` があれば、RSpec はもともとその根を見つける。
そのときこの行は、rspec-core の内部の状態を書き換えるただ一つの部分である固定（`RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); `）を省く。

## Rails アプリ

Rails アプリの候補は、アプリ自身の spec と同じく `require "rails_helper"` で始まる RSpec のファイルか、`require "test/test_helper"` で始まる Minitest のファイルである。
候補はアプリのファクトリーとテスト用データベースを使える。
`context` はファクトリーをそれが作るクラスまでたどるので、`create(:loan)` は `Loan#initialize` を指す。

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
`database.yml` がこの変数を使っていないことは、`run` が候補を動かす前に見つける。
`run` は各側の `config/database.yml` を、その側の `TEST_ENV_NUMBER` と、`--env` で渡した `DATABASE_URL` があればそれも使って、Active Record と同じように読む。
base と head がサーバー上の 1 つのデータベース、または絶対パスの 1 つの SQLite ファイルを指すとき、`--workers` の値にかかわらず、`--serial` と同じく一度に 1 つのプロセスだけを動かす。
そのときテキストの報告は `serial` と次の行を出す。

```text
warning: base and head use one test database, lending_test, so jitcatch ran one process at a time. To run them at once, end the test database name in config/database.yml with <%= ENV["TEST_ENV_NUMBER"] %> and create the numbered databases: for n in 1 2; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done
```

`--env DATABASE_URL` を渡したときは、URL がすべてのチェックアウトのデータベースを決めるので、この行はまず `DATABASE_URL` を渡さないように言う。
`Rails.application` を呼ぶもののように、起動したアプリの中でしか読めない `database.yml` からは答えが出ないので、実行は本来のプロセス数のまま進む。
PostgreSQL 16 を使うサンプルアプリで `db/schema.rb` も変える変更では、6 つのファイルが、ロードアベレージ 11 から 18 では 1 つずつで 40 秒から 50 秒、番号付きのデータベースで 18 秒、ロードアベレージ 2 ではそれぞれ 32 秒と 9 秒かかった。
1 つのデータベースを共有したまま `--workers 3` で動かすと、2 回のうち 1 回、変更が原因でない `loan_spec.rb#load` の行が報告された。
この確認が入る前は、1 つの例を持つ 6 つのファイルに `--serial` で 34 秒、番号付きのデータベースで 6 秒から 10 秒かかった。

それぞれのチェックアウトには、git が追跡するファイルしか無い。
認証情報を読むイニシャライザーは、`config/master.key` が無いのでそこで失敗する。
鍵は `RAILS_MASTER_KEY=$(cat config/master.key) jitcatch run --env RAILS_MASTER_KEY BASE HEAD TESTS_DIR` のように渡す。

ファイルごとに、それぞれの側でアプリを 1 回起動する。
サンプルアプリ（4 CPU）では、example が 1 つずつの 6 ファイルに 9.8 秒、同じ 6 つの example を 1 ファイルにまとめると 1.9 秒かかった。
bootsnap のキャッシュは、チェックアウトごとに空から始まる。
1 ファイルでは bootsnap ありで 3.7 秒、`--env DISABLE_BOOTSNAP` で `DISABLE_BOOTSNAP=1` を渡すと 2.5 秒だった。
6 ファイルでは bootsnap ありで 8.0 秒、なしで 9.8 秒だった。

## インストール

`gem install jitcatch` で `jitcatch` コマンドが入る。
`Gemfile` のあるアプリでは、代わりに [クイックスタート](#rails-アプリでのクイックスタート) のとおり `:development, :test` グループに gem を足し、`bundle exec jitcatch` で走らせる。
実行時の依存はない。
このリポジトリのチェックアウトからも使える。
その場合は `bin` ディレクトリを `PATH` に置く。

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
スキルは `jitcatch` コマンドを走らせるので、gem も入れておく。

CLI を使わない場合は、`skills/jitcatch` をエージェントの skills ディレクトリへコピーまたはシンボリックリンクする（例: `.agents/skills/`、`.claude/skills/`、`.cursor/skills/`）。

## 限界

- 呼び出しを数えるのは、レシーバのクラスがソースに書かれているときだけである。
  `self`（レシーバなしを含む）、定数（`Cart.build`）、`self.class`、それらの `new`、そしてクラスが一つの `Const.new` だけを代入するインスタンス変数がこれに当たる。
  メソッドの中のすべての代入が同じ `Const.new` であるローカル変数（`repo = Repo.new; repo.read`）もこれに当たる。
  ソースが型を決めない値は、Rails がその名前から決めるクラスがそのメソッドを定義していれば、そのクラスへの呼び出しになる。
  引数とブロック引数（`Gate#check(loan)` の中の `loan.approve`）、どの代入も `Const.new` でないローカル変数、そしてどの代入も `Const.new` でないインスタンス変数（`@loan = loan`）は、どれも `Loan` として読む。
  `belongs_to :borrower` や `has_one :borrower` が定義する読み出しは `Borrower` を返すものとして読み、`class_name:` に文字列があればそのクラスとして読む。
  そのため `Loan#approve` の中の `borrower.approved_cents` は `Borrower#approved_cents` を呼ぶ。
  polymorphic の関連はどのクラスとしても読まない。
  メソッドやクラスがその変数に代入する `Const.new` と名前が食い違うときは、どのクラスとしても読まない。
  同じクラスのメソッドが返す値への呼び出し（`emitter_for(format).render`）は、そのメソッドが定数と nil だけを返すとき（`case`、`if`、三項演算子を通して）、返しうる定数それぞれへ向かう。
  二つの違う定数を代入したローカル変数、どのクラスも指さない名前、それ以外の戻り値への呼び出しは辺にならないので、`reachable_from` が呼び出し元を落とすことがある。
  そうした呼び出しは、送る名前が変更メソッドの名前か、その `reachable_from` にあるメソッドの名前であれば、その変更メソッドの `dynamic_callers:` に `Emit.looked_up (render)` のように出る。
  クラスが定義していないメソッドを `self` に呼ぶと、その名前を持つ索引上ただ一つのメソッドへ向かう。
  モジュールやスーパークラスのメソッドのためである。
  インスタンスメソッドからはインスタンスメソッドだけが対象になる。
  `Const.new` と、クラスメソッドの中でレシーバなしに呼ぶ `new` は、そのクラスの `initialize` へも向かう。
  クラスが定義していなければ、スーパークラスをたどって最も近い `initialize` へ向かう。
  そのため `Runner.new` の呼び出し元は `Runner#initialize` とそこから呼ぶメソッドに届く。
  スーパークラスは Ruby と同じく、そのクラスの外から探す。
  そのため `module Shop` の中の `class Error < Error` は外側の `Error` を指す。
  `reachable_from` は 4 回の呼び出しまで呼び出し元をたどり、`new` から `initialize` へ入る一歩はその 4 回に数えない。
  残すのは近い順に 8 個までである。
  `--json` の `reached_by` は、深さも個数も限らず、すべての呼び出し元を持つ。
  `caller_depths` は、その呼び出し元それぞれから最も少ない呼び出しの回数を持つ。
  `run` は言及と関連 id にこちらを読むので、上から入るテストも、5 回以上の呼び出しの先にある変更メソッドを名指しできる。
  たとえばコントローラとサービスを通るリクエストスペックや、`CLI.start` を呼ぶ CLI のテストである。
  そうしたテストはたいていの変更メソッドに届くので、その行はふつう `related:guess` になり、そのメソッドが一覧に入る。
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
  変更されたコンストラクタの `built_by:` にある呼び出しも同じく言及になる。
  Active Record のモデルへの `Loan.create!` や、FactoryBot の呼び出し（`create(:loan)`、`build(:loan)`、`create_list(:loan, 2)`、`build_stubbed(:loan)`）がこれに当たり、後者は `mentions` に、保存する呼び出し（`create`、`create_list`、`create_pair`）なら `create(:loan)`、保存しないものなら `build(:loan)` として出る。
  その名前のメソッドを自分で定義するファイルはそのメソッドを呼ぶので FactoryBot の呼び出しにならず、`attributes_for` はオブジェクトを作らない。
  テストが名前を書いたクラスか、`.new` で作ったそのインスタンスに送る呼び出しは、`Index.parse` や `Cart#total` のようにそのクラスと一緒にも出る。
  同じ名前の変更メソッドが複数あるとき、関連 id はそのクラス(または名前がそれで終わるクラス)のものになる。
  スーパークラスが定義するメソッドのように、そのクラスに該当するものがなければ、全部を残す。
  テストがリポジトリの定義しない定数にだけ送るメソッド名は、`File.write(path, text)` や `Dir.mktmpdir` のように、言及にならない。
  そのため `File.write` は、`Emitter.write` から届く変更メソッドを指さない。
  `emitter.send(:write)` は `emitter` に `write` を送るので、両方を書くテストは `write` に言及する。
  名前をリテラルで渡す `send`、`__send__`、`public_send` はコードの中でもその名前の呼び出しとして読むので、メソッドの中の `send(:helper)` は `helper` に届く。
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
- データベースサーバーを使う Rails アプリの base と head は、両方のリビジョンの `config/database.yml` が `TEST_ENV_NUMBER` でテスト用データベースを名付けていない限り、1 つのテスト用データベースを共有する。
  そのとき `run` はプロセスを 1 つずつ動かす（Rails アプリの節を参照）。
  起動したアプリの中でしか読めない `database.yml` では、共有しているかを判断できない。
  MySQL では動かしておらず、共有する名前は Active Record による `database.yml` の読み取りだけで試した。
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
