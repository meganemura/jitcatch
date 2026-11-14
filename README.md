# jitcatch

jitcatch keeps the Ruby tests that pass on the parent of a change and fail on the change, and names the changed method each one reaches.

## Quick start in your Rails app

You need Ruby 3.3 or newer, git, and an app whose specs run with RSpec (`rspec-rails`). Run each step from the app's root.

### 1. Add the gem

Add jitcatch to the `:development, :test` group of the app's `Gemfile`, then run `bundle install`. jitcatch has no runtime dependency, so it adds no other gem to the bundle.

<!-- rails:gemfile -->
```ruby
group :development, :test do
  gem "jitcatch", require: false
end
```

SQLite at the Rails default path needs no setup. When the test database is PostgreSQL or MySQL under one name, jitcatch finds that base and head would share it and runs one process at a time, with a `warning:` that names the line to change in `config/database.yml` to run them at once, as [Rails apps](#rails-apps) shows.

### 2. Pick a commit

A good first target is a recent commit that changed a model method with a few branches and an existing spec. List the last commits that changed a model:

<!-- rails:pick -->
```sh
git log --oneline -n 5 -- app/models
```

### 3. Write one spec and run jitcatch

Write one spec that states what the method did before that commit. Put it in `tmp/jitcatch`, which git ignores, start it with `require "rails_helper"`, and use the app's factories as its own specs do. Then run jitcatch on the commit. Replace `Loan`, `approve`, the expected result, and `c3ef899` with your model, its method, what the method returned before the commit, and the commit you picked.

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
bundle exec jitcatch run c3ef899~1 c3ef899 tmp/jitcatch
```

## What you will see

This output is from a small sample app: Rails 8.1 with FactoryBot and SQLite, where `Loan#approve` asks a senior officer to approve a large loan. `git log` lists two commits:

<!-- rails:pick-output -->
```
c3ef899 Ask a senior officer from 10000 cents.
e994a60 Characterize Loan#approve.
```

The last commit asks a senior officer from 10000 cents, where it used to ask only above 10000. jitcatch prints this:

<!-- rails:output -->
```
jitcatch run
version 0.2.1
base e994a60bff5a85b3bcc92960dd251d598b15835a
head c3ef8997c50fc389a24ec4aa3f79caca2d6437b9
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

The spec passed on the parent and fails on the commit, so it is `reported`: the commit changed what the old code did. `expected:` is the old result and `got:` is the new one. `m01` is the changed method the spec reaches, `Loan#approve`. Next, read the commit message. This one asks for the change, so the row is intended. Without that sentence, the row would be a likely regression. Run the `rerun:` line to see the failure again, and run `bundle exec jitcatch context c3ef899~1 c3ef899` to see the old and new source of each changed method. A spec that fails on the parent too describes the new behavior, so it is `fail_on_base` and is not evidence. jitcatch boots the app in a new checkout of each side and waits up to 60 seconds for each spec file there. When a row times out, its `hint:` line says what to pass or raise.

## Try it without an app

You need Ruby 3.3 or newer and git.

```sh
gem install jitcatch
```

Paste this into a shell in an empty folder. It makes a git repository with two commits. The second commit means to waive the fee on an empty order, and it also stops shipping an order of exactly 50 for free. Then it writes three candidate tests and runs jitcatch.

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

jitcatch prints this. The two commit ids are your own.

<!-- quickstart:output -->
```
jitcatch run
version 0.2.1
base 81b05b22f14f2b5a1e580c048856a5e9d9b25b85
head 7c53dd7485d4c994d97bddd3cb7bd5481a337b61
reruns 2
timeout_s 10
tests:
  t01 fail_on_base ShippingTest#test_empty_order_has_no_fee shipping_test.rb
    base: fail Minitest::Assertion Expected: 0
      Actual: 5
    head: pass
  t02 reported ShippingTest#test_fifty_ships_free shipping_test.rb m01
  t03 no_signal ShippingTest#test_small_order_pays_five shipping_test.rb
counts generated=3 no_signal=1 fail_on_base=1 candidates=1 flaky=0 discarded=0 reported=1
assess:
  c01 ShippingTest#test_fifty_ships_free base=pass head=fail m01 assertion,report,touches:changed_method
    Expected: 0
    Actual: 5
    rerun: ruby -Ilib -I. candidates/shipping_test.rb -n ShippingTest#test_fifty_ships_free
```

`test_fifty_ships_free` passed on the parent and fails on the change, so it is `reported`: the change broke a claim the old code met. `test_empty_order_has_no_fee` describes the new behavior and fails on the parent, so it is `fail_on_base` and is not evidence. `test_small_order_pays_five` passes on both sides. The commit message asks only for the empty-order rule, so the reported row is a likely regression. Run the `rerun:` line to see the failure again, and fix the comparison or change the intent.

`m01` is the changed method the reported test reaches. `jitcatch context base HEAD` prints the intent and one block for each changed method, with its old and new source:

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

## Usage

A coding agent reviewing a change writes tests for that diff. A test that only describes the new behavior fails on the parent and is not evidence of a regression. A test the parent already passes, and that fails on the change, shows a claim the old code satisfied and the new code does not. jitcatch runs the tests on both revisions, drops flakes and a few other non-signals, and prints what is left.

The method follows Meta's catching JiT tests ([Harden and Catch](https://arxiv.org/abs/2504.16472); [Just-in-Time Catching Test Generation at Meta](https://arxiv.org/abs/2601.22832)).

Ruby 3.3 or newer. No gems. `minitest` and `prism` ship with Ruby. `jitcatch --version` (or `-v`) prints `jitcatch 0.2.1`, followed by the commit, as in `jitcatch 0.2.1 (1fbcd18)`, when jitcatch runs from its own git checkout, as a gem installed from git does, and `--help` prints the commands. RSpec candidates need `rspec-core` where they run: in the project's bundle, or installed for that Ruby when the project has no `Gemfile`. `BASE` is the parent revision and `HEAD` is the change. Each must resolve to a commit. Uncommitted files are not in the diff.

You write the candidate files in a scratch directory. A Minitest file starts with `require "minitest/autorun"`, then requires the library the way the repository loads it. An RSpec file is named `*_spec.rb` and starts with `require "spec_helper"` or `require "rails_helper"`, as the project's own specs do. jitcatch runs those files. You judge each `reported` row against the intent and the diff. The intent in the brief is the commit messages from `BASE` to `HEAD`, without the trailer lines git parses at the end of each message (such as `Co-Authored-By:`). likely-regression means the behavior changed and the intent does not ask for that change. intended means the intent asks for it. unclear means the intent is not enough to tell.

`examples/fixtures/shop` is a cart priced in integer cents. A 10% volume discount applies once the subtotal reaches 10000 cents. Tax is 8%, rounded half up. The existing tests never check exactly 10000 cents. `ruby script/setup_shop` writes a git history at `examples/shop` (that directory is gitignored):

| Revision | What it contains |
| --- | --- |
| `base` | The initial cart. |
| `regression` | Adds a SAVE5 coupon and changes the threshold comparison from `<` to `<=`. The message mentions only the coupon. |
| `intended` | Lowers the threshold to 5000 cents. The message says that change is intentional. |

```sh
ruby script/setup_shop
bin/jitcatch context --repo examples/shop base regression
bin/jitcatch run --repo examples/shop base regression examples/runs/regression/tests
```

`context` prints the intent, then one block per changed method. From that run:

```
intent:
  Add SAVE5 coupon (500 cents off before tax).
  Apply the coupon with Cart#apply_coupon. SAVE5 subtracts 500 cents
  from the taxable amount before tax. Unknown codes raise
  Shop::UnknownCoupon.
```

`m05` is the threshold method:

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

`run` keeps two tests. The full text is `examples/runs/regression/run.txt`.

```
counts generated=13 no_signal=8 fail_on_base=3 candidates=2 flaky=0 discarded=0 reported=2
assess:
  c01 ThresholdTotalTest#test_at_threshold_total_includes_the_volume_discount base=pass head=fail m05 assertion,related:guess,report,touches:unchanged_caller
    related guess: Shop::Cart#volume_discount_cents (m05), ranked first of 3: Shop::Cart#coupon_discount_cents (m02), Shop::Cart#taxable_cents (m04), Shop::Cart#volume_discount_cents (m05)
    Expected: 9720
    Actual: 10800
  c02 VolumeBoundaryTest#test_threshold_is_inclusive base=pass head=fail m05 assertion,report,touches:changed_method
    Expected: 1000
    Actual: 0
```

Both reported rows are likely regressions. At exactly 10000 cents the discount is 1000 and the taxed total after the discount is 9720. Head returns 0 and 10800, which is the taxed total with no discount. The intent only adds the coupon. The three SAVE5 tests fail on base, because `apply_coupon` and `Shop::UnknownCoupon` are not there yet, so they are not candidates.

The other history is an intended change. The constant moves, and the method body does not, so `context` lists the method as `affected`.

```sh
bin/jitcatch context --repo examples/shop base intended
bin/jitcatch run --repo examples/shop base intended examples/runs/intended/tests
```

```
constants:
  [k01] modified Shop::Cart::VOLUME_THRESHOLD_CENTS lib/shop/cart.rb:7
    old: VOLUME_THRESHOLD_CENTS = 10_000
    new: VOLUME_THRESHOLD_CENTS = 5_000
    read_by: m01
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

The full text is `examples/runs/intended/context.txt` and `examples/runs/intended/run.txt`. Both reported rows are intended: the message says orders of 5000 cents or more get 10% off. A test that states the new rule directly fails on base and is not a candidate. That pass-on-base / fail-on-head result has the same shape as the regression run. The commit message is what distinguishes them.

Delete the scratch directory when you are done. Keep a test in the project's suite only when you mean to promote it. A likely-regression test belongs there after the bug is fixed. An intended-change test states the old behavior.

Characterization tests from branchout can be candidates, as Minitest files or as RSpec specs (`--format rspec`). Emit them on a checkout of the base revision with `--require-by-name`, so that each side loads its own worktree's code. A test emitted without it keeps a `require_relative` or an absolute path. That is fine when the path resolves inside the worktree, as for a test emitted under `.jitcatch/` of the checkout. When it points outside the worktree, both sides load the same file and every row is `no_signal`.

On another repository, pass `--repo` when that repository is not the working directory:

```sh
jitcatch context --repo DIR BASE HEAD
jitcatch run --repo DIR BASE HEAD TESTS_DIR
```

### A gem in a directory of a larger repository

When the gem sits in a directory of the repository, such as `ruby/` with its own `lib/`, `Gemfile`, and `Gemfile.lock`, run jitcatch from that directory:

```sh
cd ruby
jitcatch run BASE HEAD catch
```

Each candidate, the bundle check, `--setup`, and each `rerun:` line then run in `ruby/` of each checkout. `-Ilib` is `ruby/lib`, `BUNDLE_GEMFILE` is `ruby/Gemfile`, and the Bundler settings are read from `ruby/.bundle/config`. `TESTS_DIR` and the rerun line are named from `ruby/`, so the rerun line runs from where you ran jitcatch. `--repo ruby` from the repository root is the same run. The report says so under `head`:

```text
head 6af3acfb1a733406d202eaed737b7dabfbece7fa
directory ruby (candidates, the bundle check, and each rerun line run here; file paths are from the repository root)
```

The diff, the changed methods, and the backtrace frames keep their paths from the repository root (`ruby/lib/shelf.rb`), as git names them. `context` reads the locked gems from `ruby/Gemfile.lock`. The Rails parts of `context` (routes, models, controllers, and `readers:`) and the scripts under `exe/` and `bin/` are read only at the repository root.

### Options

| Flag | Commands | Effect |
| --- | --- | --- |
| `--json` | `context`, `run`, `assess` | Print the same document as JSON. |
| `--repo DIR` | `context`, `run` | Git repository to read, or a directory inside it to run from (see above). The default is the working directory. |
| `--all-readers` | `context` | Print every row under `readers:`, not the 10 that score highest. |
| `--coverage FILE` | `context` | Replace the grep of existing tests with this file. The JSON has `"format": "jitcatch-coverage-v1"` and a `tests` array. See `examples/coverage/jitcatch-coverage-v1.sample.json`. |
| `--reruns N` | `run` | Extra runs on head after a pass-on-base / fail-on-head result. The default is 2. `0` skips the flake check. |
| `--timeout SEC` | `run` | Seconds before a test file is killed. The default is 60 when head has `config/application.rb`, since a Rails app boots and loads `db/schema.rb` in each new checkout, and 10 otherwise. The minimum is 1. |
| `--workers N` | `run` | Test files that run at the same time, each worker in its own base and head worktrees. The default is 1. Each worker runs two Ruby processes at once, so more workers help only while CPUs are idle. The report is the same for every N. |
| `--number-database-url` | `run` | Adds each checkout's `TEST_ENV_NUMBER` to the database name in the `DATABASE_URL` that `--env` passes, so base and head get databases of their own (see Rails apps). It needs `--env DATABASE_URL`. |
| `--setup CMD` | `run` | Runs `CMD` with `/bin/sh` once in each checkout before the candidates, with that side's `TEST_ENV_NUMBER`, `DATABASE_URL`, the variables `--env` passes, and `RAILS_ENV=test` unless `--env` passes another, as `--setup 'bin/rails db:create db:schema:load'` does to load each side's schema into its own test database. A failed command exits 3. |
| `--serial` | `run` | Runs one Ruby process at a time: a file's base run, then its head run. For candidates that write a fixed path outside the worktree or listen on a fixed port. It takes no `--workers` above 1. `run` also runs this way, with a `warning:`, when base and head of a Rails app share one test database (see Rails apps). The text report prints `serial` and `--json` records `"serial": true`. |
| `--env NAME` | `run` | Pass this variable from your environment to the test processes. Repeat it for more names. The run records the names, not the values, and lists a name that is not set on an `env_unset` line, a note that the run went without it, so the code used its own default. It takes a name only: `--env DB_PORT=55801` stops with the shell form to use, `export DB_PORT=<value>` and then `--env DB_PORT`, because each rerun line reads the value from your shell. |

| Command | Arguments |
| --- | --- |
| `jitcatch context` | `BASE HEAD` |
| `jitcatch run` | `BASE HEAD TESTS_DIR` |
| `jitcatch assess` | `RUN.json`, the file written by `run --json` |

To review the first commit, pass `ROOT^` as `BASE`. The parent of a root commit is read as the empty tree.

When `BASE` is not an ancestor of `HEAD`, the diff also undoes the commits only `BASE` has. `context` and `run` then print a `warning:` line under `head` that counts those commits and names the merge base to pass as `BASE` instead. When the two resolve to the same commit, the `warning:` line says so.

`assess` reprints the run's warnings, the counts, and the candidate rows. It applies the same rules as `run`. A row shows the first line of the failure, or the expected and actual lines of a Minitest diff. When one of those is longer than 100 characters, the row shows the Hash entries or the Array elements that differ, or a window around the first column that differs with a `^ column N` marker. The marker shows only when the added line replaces the removed one: two lines from different places of the diff are each cut to 61 characters. A failed `assert_raises(X)` also shows Minitest's `Class:` and `Message:` lines, which name the error that came instead. RSpec's `be` and `equal` show their `expected` and `got` lines, and an rspec-mocks failure on unexpected arguments shows the call and its `expected:` and `got:` lines, under `assess:` and under a `fail_on_base` row's `base:` alike. An error row that was raised from another error adds that error's class and message, as `cause: KeyError: key not found`. RSpec prints the cause itself. Minitest does not, so jitcatch loads `lib/jitcatch/minitest_report.rb` into each Minitest candidate's process with `-r`, which adds the cause to Minitest's error text; the `rerun:` line does not load it. A row line longer than 300 characters, such as a whole frozen Array in a `FrozenError`, keeps its first and last 150 characters around `... (+N characters; the whole message is in --json) ...`, since the end of an error a matcher got often holds what differs after a long path. When that line is the first of a message with RSpec's `Diff:` under it, as `have_attributes` prints the record and both attribute Hashes on one line, the row adds the diff's removed and added lines (at most 8), such as `-:state => "pending",` and `+:state => "draft",`. `--json` keeps the whole message.

```sh
bin/jitcatch run --json --repo examples/shop --reruns 2 --timeout 10 base regression examples/runs/regression/tests > run.json
bin/jitcatch assess run.json
bin/jitcatch assess --json run.json
```

| Exit | Meaning |
| --- | --- |
| 0 | The command finished. A run that found candidates still exits 0. |
| 1 | Usage error. |
| 2 | Git error. |
| 3 | `run` tested nothing: a side failed its setup check, no candidate file loaded on either side, or every row timed out, or found no database or no table, on a side. |

### Results

| Bucket | Meaning |
| --- | --- |
| `no_signal` | Passed on base and on head. |
| `fail_on_base` | The parent did not satisfy the test. Often the test only describes a new feature. The text report prints what base did under the row, as `base: error NoMethodError undefined method 'apply_coupon' for an instance of Shop::Cart`, and what head did on the next line: `head: pass` when the change makes the test pass, head's own failure, or `head: fail, the same as base`. |
| `flaky` | Passed on base, failed on head, then a rerun did not fail the same way. Dropped. |
| `discarded` | Passed on base and failed on head, then a rule removed it. Still listed under `assess:`. |
| `reported` | Passed on base and failed on head, and no rule removed it. Judge this row. |

`generated` counts test methods. `candidates` counts stable pass-on-base / fail-on-head tests before the discard rules. `reported` is what remains.

A tag is a hint, not the judgment. `touches:changed_method` means the test names a method the diff changed. `Owner.new` names the `initialize` of that owner alone (`Mismatch.new` is not `Spec#initialize`), and a changed constructor is the related method only when the test names no other changed method and goes through no changed method's caller. `touches:changed_constant` means it names a constant the diff changed. `touches:changed_dependency` means the error came from inside a gem whose locked version changed. An error that starts inside any gem does not get `touches:changed_method`. `touches:unchanged_caller` means the test goes through an entry point the diff did not edit, and that entry point reaches a changed method. `discard:signature_change`, `discard:load_error`, `discard:timeout`, `discard:no_database`, and `discard:no_table` name the rule that removed a candidate. `discard:signature_change` applies only when the test itself makes the call that a removed method or a new signature broke, or calls `new` of a `Data` or `Struct` class whose members the diff changed, as `Record.new(...)` failing with `missing keyword: :media`. Such a row is not a finding, and its next line says what changed: `candidate is out of date with head: CatalogService::Record (k07) changed its definition; update the call at ../cand/stale_spec.rb:5 to head's code, or drop the test`. `out_of_date` in `--json` holds its `id`, `name`, `change` (`removed`, `parameters`, or `definition`), and `call`. When unchanged code makes it, such as `class B < A` still calling the `A#helper` that head removed, the row is reported with `caller:unchanged:lib/b.rb:5`, the line of that call (`caller:changed:` for a line the diff wrote or a line in a changed method; `changed_lines` in `--json` lists the head lines each file's hunks wrote). The related id (`m05`, or `-` when there is none) is the downstream changed method when several changed methods sit on the path. When the failure's backtrace runs through changed methods, it is the innermost of them, and that pick is not a guess: the outer frames only called it. A frame's line is read as a line of head, so it never hits the method that held that line on base. `related:guess` means the evidence that picked the id points at more than one changed method, as when the test names only an unchanged caller that reaches several; the row's next line names them all with their ids, as `related guess: Shop::Cart#volume_discount_cents (m05), ranked first of 3: Shop::Cart#coupon_discount_cents (m02), Shop::Cart#taxable_cents (m04), Shop::Cart#volume_discount_cents (m05)`, and `method_ids` holds them in `--json`. The pick prefers a method that existed on base over one the diff added, except over an edit that only adds a call to an added method (`forwards_to_added` in `--json`), as `net - volume` becoming `net - volume - coupon(n)` does: the new value comes from the added method. Among methods the test reaches only through an unchanged caller, the pick is the one the most calls below the entry point the test names, so a request spec that reaches `LoansController#officer` one call down and `Borrower#approved_cents` five calls down picks `Borrower#approved_cents`; `caller_depths` in `--json` holds those counts. A test that starts a changed script picks the script's `exe/tool <main>` ahead of the changed methods that code calls: every start runs it, and each method below it runs only for the command that picks it, so a test of `quint_driver bogus` whose usage text changed reads `related guess: exe/quint_driver <main> (m01), ranked first of 3: exe/quint_driver <main> (m01), QuintDriver::Spec#outline (m10), QuintDriver::Targets.report (m14)`. On a row where head stopped raising the error the test expects (`X expected but nothing was raised.`), the pool leaves out an edit that only changes the arguments of a `raise` (`edits_only_raise` in `--json`): that method sits below every caller, but head no longer reaches it, and the cause is usually in the code that called it. When only the id would order the best two, the row names no pick: the line reads `related guess: none; the test reaches 7 changed methods equally and no frame of head's failure is in one: Book#apply_catalog_record (m02), LoanRules.for (m03), ...`, and it ends with a next step: find what makes head's value in those methods, or in a changed file that holds no method, such as a view, from the `git diff --stat BASE HEAD` it prints. The row shows `-` in place of the id, and `method_id` is `null`. Such a row gets `touches:changed_method` when the test names any method of `method_ids`, not only the one with the lowest id. `message_varies` means head failed the same way on each rerun with a message that moved, and base passed on each rerun; compare a field the test controls rather than the whole record. `related:dynamic` means no changed method is related, but the test calls a method from `dynamic_callers:`; the row's next line says so, as in `related: none, Emit.looked_up sends render to a receiver the source does not name`.

## How it filters

`context` diffs the two revisions and maps hunks onto methods with Prism. Changed methods are `m01`, `m02`, and so on. An executable under `exe/` or `bin/` with no suffix and `ruby` on its `#!` line is read too: its code outside a `def`, a class, or a module is one method, `exe/tool <main>`, so a change to its usage text is listed, its `tests:` are the test files that write its path, and a test that starts it mentions it. When `Gemfile.lock` changed, a `dependencies:` block lists each gem as `gem old -> new`. A changed constant is `k01`. A class or module that only one side defines anywhere is a constant too, `added` or `removed`, shown by its header line. A method that did not itself change but reads that constant is `affected` (`via=k01`). A method that leaves one file while head defines the same name in another file, test files included, is `moved`, shown at its new place with `moved_from=` naming the old file; when several files define it, one the diff touched comes first. A constant that moves the same way with the same value is `moved` with `moved_from=` too, and a method that reads it is not `affected`. A constant that moved and took a new value is `modified`, with `moved_from=`. A reader or writer from `attr_reader`, `attr_writer`, `attr_accessor`, or a `Struct.new` or `Data.define` member list is a method, with the one-name form (`attr_reader :seed`) as its source, so a name dropped from such a line is `removed` and the names left on it do not change. A list given as `*FIELDS` counts when the same file set `FIELDS` to a list of symbols before it, as in `FIELDS = %i[x y].freeze`; each member then takes the line of its symbol in that list. Three Active Record macros of a class body define methods too. `scope :recent, -> { ... }` (or `scope(:recent) { ... }`) is the class method `Post.recent`, with the whole statement as its source, and the calls in its body are calls from `Post.recent`. `delegate :name, to: :author` is `Post#name` (`Post#author_name` with `prefix: true`), with the one-name form and the options as its source, so a change to `to:` changes every name on the line. `enum :status, { draft: 0, live: 1 }` gives each value `Post#draft?`, `Post#draft!`, `Post.draft`, and `Post.not_draft`, with `prefix:`, `suffix:`, `scopes: false`, and `instance_methods: false` applied, and its source is that one value (`enum :status, draft: 0`), so changing one value changes only its four methods. The `enum status: {...}` form that Rails 8 removed is not read. A Grape endpoint is a method too: in a class whose superclass is `Grape::API` (or a name that ends in `API` or `Api`, as an app's own base class does), `post "/refresh" do ... end` inside `resource :things do` is `Things#POST /things/refresh`. Its path joins the class's `prefix` and the segments of `resource`, `resources`, `namespace`, `group`, `segment`, and `route_param :id` (`:id`). Its source is the block, with the `desc` and `params` statements just before it, and the calls in the block are calls from the endpoint, so a method it calls shows it under `reachable_from`. A request a test sends, as `post "/api/things/7/refresh"`, names an endpoint with the same verb whose segments end the path, with a `:param` matching any one segment and any segments before them taken as a mount point. A path that interpolates a string constant the file assigns, in the API class (`namespace VERSION`, `post "#{ACTION}/now"`) or in the test (`post "#{API_ROOT}/things"`), reads as that string. In a test, any other interpolation matches any one segment (`"/things/#{thing.id}/refresh"`), or any mount point when the path starts with it (`"#{api_root}/things"`). The `desc` and `params` before a `route_param` or another path block belong to the first endpoint inside it. Such a test is listed under `tests:` and `entry_point_tests:`, and a candidate that sends it gets `touches:changed_method`. An endpoint whose path the API class computes any other way keeps that part as its source in braces, as `Books#GET /books/{Settings.legacy}/list`, matches no request, and gets a `warning:` that says so with its file and line. In a Rails app, `context` and `run` read the routes `config/routes.rb` draws (`resources`, `resource`, `namespace`, `scope` with `module:`, `as:`, or `controller:`, `member`, `collection`, `on:`, `root`, and a verb with `to:`, `=>`, or `controller:` and `action:`), so a request a candidate sends to a path helper (`post things_path`, `patch thing_url(thing)`) or to a path names the controller action that serves it, as `ThingsController#create`. Helpers and controllers take the names Rails gives them with Active Support's inflections and the literal `irregular`, `uncountable`, `singular`, `plural`, and `acronym` calls in `config/initializers/inflections.rb`: `resources :people` draws `person_path`, `resources :news` draws `news_index_path` and `news_path`, and `inflect.acronym "API"` makes `resources :api_keys` reach `APIKeysController`. A rule that file builds at run time is not read. A changed controller action that the routes draw lists under `tests:` each test file whose requests reach it, and each controller test that names the controller and calls the action as `post :create`, with what it sends (`spec/requests/things_spec.rb via POST things_path`); a grep of the action's name matched `create(:thing)` and missed `post things_path`. An action no route draws keeps the grep. A helper drawn any other way, as by a `draw` file, a loop, or a concern, is not read: `run` prints `warning: 1 candidate request names a path helper config/routes.rb does not draw (report_path), so it is tied to no controller action.` A `def` or reader inside a conditional of the class body (`attr_reader :x if cond`) counts. The branches read as if each ran in order, so a bare `private` in a branch carries past the conditional. A definition in a Concern's `included do`, `prepended do`, or `class_methods do` block counts too. Each method block has the old and new source, call sites in the library, the entry points that reach it (`reachable_from`), and existing tests that mention it. A changed `initialize` also shows `built_by:`, the calls besides `new` that run it: `create`, `create!`, and `build` on an Active Record model, and `build(:loan)` and `create(:loan)` for each FactoryBot factory that builds the class. Its `tests:` line lists each test file that calls one of those or `Owner.new`, with the calls it makes (`spec/models/loan_spec.rb via create(:loan)`). No test calls `initialize` by that name, so a constructor gets no grep hits. A reader or member from `attr_reader` or `Data.define` (`Targets::Hit#code`) is most often a short word, so its grep hits are only the files that also name its class or the namespace around it (`Hit` or `Targets`). The code of a fixture project under `test/` or `spec/`, in its `app/`, `lib/`, `config/`, or `db/` (`test/fixture/depot/app/`), tests nothing and is not listed under `tests:`. Factories are read from `spec/factories` and `test/factories` without loading them: the class comes from `class:` (a constant, a string, or a symbol), then from the parent (`parent:`, or the factory it nests in), then from the camelized name, and an alias in `aliases:` builds the same class. A factory also counts for each class its associations build, through their own associations too: a bare `borrower` that names a factory, `association :borrower` (or `factory: :user`), or an attribute block that calls `association`, in the factory or one it inherits from, so `create(:loan)` saves a `Borrower` too. An association in a trait counts only for a call that names the trait: a trait `:cosigned` of `:loan` that builds a cosigner adds `create(:loan, :cosigned)` and `build(:loan, :cosigned)`, not `create(:loan)`, and a test that writes `create(:loan, :cosigned, amount_cents: 5)` mentions both `create(:loan)` and `create(:loan, :cosigned)`. A factory takes the traits of its parent and of the factory it nests in. A trait defined outside a factory, and a trait that includes another trait, are not followed. A factory whose class the source does not settle is not followed and is listed under `factories_skipped:` with the reason: a `class:` computed at run time, a parent that is not a factory read there, or a class that no file defines, which an inflection the app configures can cause (`ApiKey` against `APIKey`). A factory that builds a Ruby value rather than a class of the app (`class: Hash`, as for the shape of an API response, or `Array`, `Data`, `Object`, `OpenStruct`, `Set`, `String`, `Struct`) is left out and not listed. A method that an Active Record model's class body names in a callback or a validation (`after_save :count_save`, `validate :check`, or an `if:` or `unless:` of either, as in `validates :amount, presence: true, if: :checked?`) shows `run_by:`, the calls that run it by Rails's rules, followed by the lines that name it. A save callback lists `Loan.create`, `Loan.create!`, `Loan#save`, `Loan#save!`, `Loan#update`, and `Loan#update!` (a create callback leaves out the updates, an update callback the creates), with `create(:loan)` and `build(:loan)` for each factory of the class. A validation adds `Loan#valid?`, `Loan#invalid?`, `Loan#validate`, and `Loan#validate!`. An `on:` on a validation or on a commit or rollback callback keeps only the calls of that context, and the line shows it: `before_validation :mark_pending, on: :create` lists no update, so a method that calls `update!` does not reach it, and `on: :update` lists no create and no factory. A context of the app's own (`on: :publish`) runs only from a call that takes one, so it lists `Loan#save`, `Loan#save!`, and the four validation calls. An `on:` that is not written as symbols narrows nothing. A destroy callback lists `Loan#destroy` and `Loan#destroy!`. A method that such a callback reaches (`reachable_from`) gets the same line. A method outside the tests that makes one of those calls, as the source writes it (`Loan.create!` in `LoanDesk.open`, or `update!` inside a method of `Loan`), joins `reachable_from` with its own callers, so a test that calls `LoanDesk.open` names the callback. A call on a local or an instance variable the source does not type, such as a parameter, is read as a call on the model Rails names it after, so `loan.save!` in `Teller#renew(loan)` reaches a save callback of `Loan`, and `record.save!` reaches none. Its `tests:` lists each test file that makes one of those calls (`spec/models/loan_spec.rb via Loan.create!`), next to the grep hits, and `run` counts the call as a mention of the method. `Loan#save` counts when the test's source settles the record's class (`loan = Loan.new`). `build(:loan)` does not save, so it counts only in a test that also makes one of the record calls the callback lists, as in `build(:loan).save!` or `expect(build(:loan)).to be_valid`, where `be_valid` calls `valid?`. That call's receiver is not checked, since a local the source does not type holds the built record, so a test that saves another record next to `build(:loan)` counts too. A test that only builds gets no `tests:` hit and no mention in `run`. A callback line in a Concern, one a parent class declares, and a call on a subclass are not followed. When no test mentions it, `entry_point_tests` lists the test files that name the class of a public entry point in `reachable_from` and call a method of that entry point's name. `--coverage` uses the line lists in the JSON file instead of the grep. The brief ends with one `entrypoints <Const>:` section for each class or module that holds a changed method. It lists that class's public methods on head (on base when head has none), changed ones first with their change kind, then the rest as `unchanged`, at most 12, with the ones that reach a changed method first and `(+N more)` for the methods left out. A class that defines `initialize` on either side shows `Owner.new` with the role of `Owner#initialize` in its place, unless the class makes `new` private (`private_class_method :new`, or `private :new` inside `class << self`). These are the methods a test can call, and `run` counts their names as mentions.

`run` adds a git worktree for each revision, copies the scratch directory to `.jitcatch/` in that worktree, and runs each file in its own process:

```sh
ruby -Ilib -I. -r<jitcatch>/lib/jitcatch/minitest_report.rb .jitcatch/<file> --seed 1
ruby -Ilib -I. -e 'require "rspec/core"; exit(RSpec::Core::Runner.run(ARGV))' -- \
  --format json --out .jitcatch-report.json --seed 1 --backtrace --no-color .jitcatch/<file>_spec.rb
```

That file writes each Minitest result to `.jitcatch-report.json`, and the row takes its name and status from there, not from what Minitest prints. A row names one test whatever the tests print, and when they run at once (`parallelize_me!`).

A file named `*_spec.rb` runs with RSpec, unless it requires `minitest` (a minitest/spec file). RSpec reads the worktree's `.rspec`, so `--require spec_helper` there still loads, and puts `spec/` on the load path. The formatter given on the command line replaces the ones `.rspec` names. One example is one row, named by its full description (`Cart#total sums the prices`), and the text report shows its line (`cart_spec.rb:11`). An expectation failure is `fail`, any other error is `error`, and `pending` is `skip`. An error while RSpec loads the file is one `<file>#load` row, as for Minitest.

When a revision has a `Gemfile`, its files run with `-rbundler/setup` and `BUNDLE_GEMFILE` set to that `Gemfile`, so each side loads the gems its own lock names. Each side also gets the checkout's `.bundle/config` (the settings `bundle config set --local` writes, such as `BUNDLE_WITHOUT`), which git does not track; a relative `BUNDLE_PATH` keeps naming the checkout's directory. Before any test runs, `run` checks once per side that the side can load its bundle and the test framework (`minitest` for a Minitest candidate, `rspec-core` for an RSpec candidate). Without a `Gemfile`, the check asks the Ruby that runs jitcatch for the framework. A successful run prints `bundle base ok` for each side that has a `Gemfile`. When a side fails the check, for example because a locked gem is not installed, every candidate would fail to load there and read as `fail_on_base` or as a regression. So `run` stops with exit status 3 and names the Ruby that ran the check (its version and path), each failed side, the command that failed, and the last lines of its stderr:

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

A side can pass that check and still fail to boot what every candidate requires, such as a Rails app whose test database does not exist. When every file is a `<file>#load` row that errored on both sides, no row can tell base from head, so `run` stops with exit status 3 too. The first line is then `jitcatch: every candidate file failed to load on both sides, so no row can tell base from head`, and each side has a `load base failed:` line with the first file's rerun command and the error under it.

The text goes to stdout, as every report of exit status 3 does, and stderr stays empty. With `--json`, stdout holds `{"command": "run", "error": "setup_failed", "stage", "rails_app", "ruby": {"version", "path"}, "base", "head", "setup_failed": [{"side", "commit", "command", "stderr", "not_passed"}]}` instead, where `stage` is `setup` or `load`. `rails_app` is true when head has `config/application.rb`, and only then does a `load` report add the hint about `config/master.key` and `RAILS_MASTER_KEY`. `assess` refuses that document. A failed side names each Bundler setting (`BUNDLE_WITHOUT`, `BUNDLE_PATH`, and other `BUNDLE_` variables) set in your environment that `--env` did not pass, on the `not passed:` line (`not_passed` in `--json`).

A run can also finish with rows that each say nothing about the change: every row timed out on a side, or found no database there (`NoDatabaseError`, `ConnectionNotEstablished`, `DatabaseConnectionError` on base or head), or found no table there (an `ActiveRecord::StatementInvalid` from `PG::UndefinedTable`, MySQL's `Table '...' doesn't exist`, or SQLite's `no such table` or `Could not find table`), as in a database that `db:create` made and nothing filled. Such a run tested nothing, so it exits 3 too and must not read as a change with no finding. Its text starts with `jitcatch: no row ran to a result on both sides (6 of 6 timed out), so this run cannot tell base from head`, followed by the usual report, so each row keeps its hint. The parenthesis names only what the rows show: `timed out`, `found no database`, `found no table`, or several joined by `or`. When the rows found no table, a second line says to load the schema; with `--number-database-url` it names the numbered databases, as in `` jitcatch: load the schema into app_test_wt1_1 and app_test_wt1_2: run jitcatch again with `--setup 'bin/rails db:create db:schema:load'`, which loads each side's schema into its own database, or call `ActiveRecord::Migration.maintain_test_schema!` in the test helper ``. Only a command run in each checkout can load that side's schema; when `--setup` already ran one, the line names it and asks for one that loads each side's schema. `--json` prints the usual run document, and its `untested` field counts those rows in every run.

Such rows beside rows that failed on base for another reason, as a candidate that only checks the arguments of a mock does, still compare no test across the change, so that run exits 3 too, and its text starts `jitcatch: no row compared base with head (6 of 7 found no table, and 1 failed on base), so this run cannot tell base from head`. A run whose rows all failed on base with none of them hidden exits 0: the fix is in the candidates, and each row's `base:` line says why. So exit 3 means `untested` is above zero and no row has a base that passed with nothing hidden. When some rows did compare, the header has a `warning:` line, as in `warning: 6 of 7 rows found no table on a side, so they checked nothing; load the schema into ...` with the same advice. A `fail_on_base` row whose base found no table has a `hint:` line under its `base:` line, `hint: base found no table, so this row checked nothing; load base's schema into app_test_1`, which names base's numbered databases, or `its test database` without `--number-database-url`.

A timeout on head alone, beside a base that passed in at most half of `--timeout`, is reported with the tag `head_only_timeout`. A slow boot does not explain it, and head may loop or wait forever, as a wait that checks a clock the test froze does. Its hint gives base's time: `hint: base passed in 0.1s; head did not finish in 5s, so head may loop or wait forever`. The row is not rerun, and it does not count toward `untested`. A base that took longer leaves a slow boot as likely, so that row is `discard:timeout`, and its hint starts `hint: head timed out after 10s, and base passed in 7.4s;`. In `--json`, base's `seconds`, rounded to a tenth, is on these rows alone, because a time differs from run to run.

The process keeps only a fixed list of environment variables and the ones named with `--env`, so a child can wait on a command or a network it cannot reach without a name your shell has. When a row timed out, its `hint:` line names, before it says to raise `--timeout`, each variable your environment sets, `--env` did not pass, and the child is likely to need: a network setting (`HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY`, `HTTP_PROXY` in either case, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS`) when head's Ruby files or a candidate require an HTTP client (`net/http`, `open-uri`, `faraday`, `httparty`, `excon`, `http`, `httpx`, `httpclient`, `rest-client`, `typhoeus`) or head's `Gemfile.lock` lists one, or a string, a backtick, or an argument list in them starts a command that fetches (`"npx `, `"npm `, `"curl `, `"wget `, and `bundle`, `gem`, or `git` followed by `install`, `update`, `clone`, `fetch`, or `pull`, as in `system("bundle", "install")`), so a spec of an app on local SQLite names none, and a command a script file runs is not seen, or a name that head's Ruby files or a candidate read with a literal (`ENV["QUINT"]`, `ENV.fetch("QUINT")`, `ENV.key?("QUINT")`). For example, `hint: base and head timed out after 10s; jitcatch did not pass HTTPS_PROXY QUINT, so add --env HTTPS_PROXY --env QUINT if the file needs them, then raise --timeout if it needs longer`. A name `--env` passed that your environment does not set comes before those, as in `hint: base and head timed out after 10s; --env QUINT passed nothing, because QUINT is not set, so set it if the file needs it, then raise --timeout if it needs longer`. With no such name, the hint is `hint: base and head timed out after 10s; raise --timeout if the file needs longer`. When head has `config/application.rb`, the hint ends with `, as a Rails app's first run in a new checkout can (it loads db/schema.rb)`. `--json` lists the names as `env_not_passed`, empty when no row timed out, and `rails_app` is true when head has `config/application.rb`.

Files named `*_test.rb`, `test_*.rb`, or `*_spec.rb` run. When none have those names, every `.rb` file runs. At most 40 files run. A test that passes on base and fails, errors, or times out on head is a candidate. So is one that times out on base and does not pass on head, since base might pass with more time; the timeout rule below discards it. `--reruns` repeats candidates on head. One disagreement makes the test `flaky`. The comparison reads the whole failure message. It masks the name directly under the temp directory, an object address (`#<Class:0x00007f...>`), and a time of day with its date (`created_at: "2026-11-04 19:02:03.212197000 +0000"`), so a `Dir.mktmpdir` path, a new anonymous class, or the time a record was saved in a message is not a disagreement. A date alone is not masked. A rerun that fails or errors the same way, with the same exception class, and only a message that differs, as a random id in a printed record does, is not a disagreement yet: base then runs the test `--reruns` times too, and when it passes each time, the row stays a candidate with the tag `message_varies` (`message_varies: true` and `base_reruns` in `--json`). A base rerun that does not pass makes the row `flaky`. The rerun line shows the first message line that moved, after `(same outcome, message differs)` when only the message moved, and each base rerun follows as `base rerun 1:`. The text report prints each rerun under a `flaky` row, cut at 300 characters as a row line is, and the JSON row keeps them in `reruns`. A timeout is not rerun.

Four rules then turn a candidate into `discarded`: a `LoadError` on head, a timeout on either side, an Active Record error on head that says its database does not exist or cannot be reached (`NoDatabaseError`, `ConnectionNotEstablished`, `DatabaseConnectionError`) or has no such table (`discard:no_table`), or a `NameError`, `NoMethodError`, or arity `ArgumentError` on a name the diff removed or whose signature it rewrote. A removed class or module counts as a removed name. An arity `ArgumentError` is `wrong number of arguments`, `missing keyword`, `unknown keyword`, or `struct size differs` (a `Struct` given more values than its members), also when `assert_raises` or RSpec's `raise_error` caught it and failed. An `ArgumentError` the code raises on purpose, such as `qty must be > 0`, stays `reported`.

The same repository and the same tests produce the same bytes. Order is fixed, the text has no timestamps, and a worktree's absolute root is written as `{worktree}` in a message (as in `{worktree}/lib/cart.rb`, and for `Dir.pwd` alone) and dropped from a backtrace frame. A message names the tests directory where it named the copy at `{worktree}/.jitcatch`, as the rerun line does: `{worktree}/candidates/fixtures/a.json` for `TESTS_DIR` `candidates/` inside the repository, and `{worktree}/../catch/tests/fixtures/a.json` for `../catch/tests` outside it. A backtrace frame in a test names `TESTS_DIR` the same way, without `{worktree}/`: `candidates/cart_test.rb`, or `../catch/tests/cart_test.rb`. The run's `--json` names that path as `tests_dir`, and `assess` reads a frame under it as the test's own. A relative `.jitcatch/`, such as `__FILE__`, stays as printed, since it cannot be told apart from text a test compares. The one exception is the start of a line in the error report Ruby prints for a file that fails to load, such as `.jitcatch/x_test.rb:2:in`, which names the file under `TESTS_DIR` as the rerun line does. A `TESTS_DIR` written as an absolute path gets no `{worktree}/`. Ruby's own prefix is written as `{ruby}/`.

Each candidate row under `assess:` ends with a `rerun:` line, and every `--json` row has `rerun`. It runs that one test again from the repository root on the checkout you have, with the candidate named by its path from the repository root, outside the repository too (`../catch/tests/cart_test.rb`), so the line names no directory of one machine. When that path climbs further than the absolute path is long, as from a checkout deep in a home directory to a directory under `/tmp`, the line and the `require_relative` warnings name the absolute path (`/tmp/catch/cart_test.rb`) instead. The run loads each candidate from a copy of `TESTS_DIR` at the root of each checkout, so a `require_relative` that leaves `TESTS_DIR` names a file of the checkout there, but from the rerun line it names the file beside `TESTS_DIR`. When the two differ, which happens unless `TESTS_DIR` sits directly under the root, `run` prints a `warning:` that names the line and both files (`a_test.rb:2 require_relative "../lib/a" loads lib/a.rb in the run but ../base/lib/a.rb from the rerun line`). Every `require_relative` counts, in a method or a block too, and `File.join` of string literals counts as the path it joins. A path the source does not settle, such as `File.join(__dir__, "helper")` or an interpolated string, gets a `warning:` that says jitcatch cannot tell whether the two load the same file, unless `TESTS_DIR` sits directly under the root. Load the repository's code with `require` and the rerun line's `-I` instead. The line runs in your shell, where every variable `--env` passed came from, so it sees them too. It holds no values, because a `DATABASE_URL` can hold a password and a report is pasted where others read it. When `--env` passed names, a `rerun env:` line under each `rerun:` line names them, and the ones the run did not have set, as in `rerun env: reads DATABASE_URL QUINT from your shell, as jitcatch run did; QUINT was unset, so the run used the code's own default`. Run the line where the same names are set. `--number-database-url` numbers the URL only inside the run, so the line uses your own database. For example: `ruby -Ilib -I. -e 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))' candidates/cart_spec.rb:11`, or `ruby -Ilib -I. candidates/cart_test.rb -n CartTest#test_total`, behind `bundle exec` when head has a `Gemfile`. A `<file>#load` or `<file>#timeout` row reruns the whole file. When head holds `spec` at its root, as a Rails app does, and the checkout you run jitcatch in can load `jitcatch/rspec`, an RSpec row reads `rspec -I. -r jitcatch/rspec candidates/cart_spec.rb:11`. The checkout can load it when its `Gemfile` lists jitcatch, as the Quick start adds it, or, without a `Gemfile`, when your Ruby has the gem installed. `jitcatch/rspec` lifts RSpec's 200-character cut on a printed object, so a `raise_error` row shows the whole error it got. Otherwise the line runs Ruby with the run's own launch, as in the example above, which lifts the cut too. That launch is not plain `rspec`, because `rspec` puts `lib/` of the nearest directory that holds `spec/` first on the load path, so a checkout under a Rails app's `tmp/` would load the app's `lib/`. The launch pins that directory to the working directory, and the run does the same in its worktrees. When head holds `spec` at its root, RSpec already finds that root, so the line leaves out the pin (`RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); `), the one part that sets rspec-core's private state.

## Rails apps

Candidates for a Rails app are RSpec files that start with `require "rails_helper"`, as the app's specs do, or Minitest files that start with `require "test/test_helper"`. They can use the app's factories and its test database. `context` follows a factory to the class it builds, so `create(:loan)` names `Loan#initialize`.

Base and head boot the app at the same time. SQLite at a relative path (the Rails default `storage/test.sqlite3`) is a file in each worktree, so the two sides never meet. A database server, such as PostgreSQL or MySQL, has one test database name for both sides, and each side loads its own `db/schema.rb` into it while the other side runs. On a change that removed a column, 1 to 6 of 6 candidates came back as `reported` load errors (`bin/rails aborted!`). jitcatch sets `TEST_ENV_NUMBER` in each checkout, the variable parallel_tests sets: `1` and `2` for base and head of the first worker, `3` and `4` for the second, and so on. When `config/database.yml` on both revisions names the test database with it, each checkout uses its own database, and the same run reported none:

```yaml
test:
  <<: *default
  database: app_test<%= ENV["TEST_ENV_NUMBER"] %>
```

Create the databases once, two for each worker, before the first run. When `spec/rails_helper.rb` (or `test/test_helper.rb`) calls `ActiveRecord::Migration.maintain_test_schema!`, Rails loads each revision's schema when it boots. Without that call, a database that `db:create` alone made has no tables, and every row would find none, so also pass `run --setup 'bin/rails db:create db:schema:load'`, which loads each side's own schema (below):

```sh
for n in 1 2; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done
```

A database made once holds one schema. After a change to `db/schema.rb`, `db/structure.sql`, or `db/migrate/` (or a second database's `db/<name>_schema.rb`, `db/<name>_structure.sql`, or `db/<name>_migrate/`), a side whose database lacks a column fails on the database and not on the code, as a request spec that gets a 500 for an unknown attribute does. `context` and `run` then print `warning: head changes the database schema (db/migrate/20261106000000_add_notify.rb, db/schema.rb), so each side's test database must hold that side's schema, or a row can fail on the database and not on the code.` When head's `spec/rails_helper.rb`, `spec/spec_helper.rb`, or `test/test_helper.rb` exists and none calls `maintain_test_schema!`, the warning goes on to name them and to say `pass --setup 'bin/rails db:create db:schema:load' to jitcatch run`, and under `--number-database-url` it names each side's databases (`base app_test_wt1_1, head app_test_wt1_2`).

`run --setup CMD` runs `CMD` with `/bin/sh` once in each checkout, after the bundle check and before any candidate, one checkout at a time. `bin/rails db:create db:schema:load` makes a numbered database that does not exist yet and loads that side's schema into it; `db:schema:load` alone fails on a database nobody made, and `db:prepare` also loads `db/seeds.rb` into a database it makes. It gets that side's `TEST_ENV_NUMBER`, the numbered `DATABASE_URL`, the variables `--env` passes, and `RAILS_ENV=test` unless `--env RAILS_ENV` passes another, so a schema load never reaches the development database. The report prints `setup CMD` (`setup` in `--json`, `null` without the flag), and the schema warning then says `` `--setup` ran `CMD` in each checkout before the candidates. `` A command that fails, or runs past `--timeout`, stops the run with exit 3: stdout starts `jitcatch: --setup failed, so no test ran` and names each side's command with the last lines of its stderr. When those lines show a database that refused the connection (`Connection refused`, `could not connect to server`, `Can't connect to MySQL server`), each side also names the database variables your shell sets that `--env` did not pass (`DATABASE_URL` and its `*_DATABASE_URL` forms, `DB_*`, `PG*`, `MYSQL_*`), as `the database refused the connection, and jitcatch did not pass DB_PORT from your shell: add --env DB_PORT` (`database_not_passed` in `--json`). A run whose every file failed to load that way names them the same way. Two sides that share one test database cannot each hold their own schema, so give them their own databases first.

In a Rails app, a reported row whose head answered 500 has the hint `hint: head answered 500, and a Rails app writes the error behind it to log/test.log; run the row's rerun line and read that log`. The checkouts are gone when the run ends, so their logs are too.

When head's database is missing, its rows are `discard:no_database`, and when it has no tables, `discard:no_table`. When `database.yml` does not use the variable, `run` finds it before any candidate runs: it reads each side's `config/database.yml` as Active Record does, with that side's `TEST_ENV_NUMBER` and any `DATABASE_URL` that `--env` passes, and when base and head name one database on a server, or one SQLite file at an absolute path, it runs one process at a time, as `--serial` does, whatever `--workers` says. The text report then prints `serial` and these lines:

```text
warning: base and head use one test database, lending_test, so jitcatch ran one process at a time; that changes how long the run takes, not its results.
warning: To run them at once, end the test database name in config/database.yml with <%= ENV["TEST_ENV_NUMBER"] %> and create the numbered databases: for n in 1 2; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done. This helps only when BASE and HEAD both have that line.
```

Past commits keep the `database.yml` they have, so for them one process at a time is the run to keep. With `--env DATABASE_URL` and a URL that names a database on a server, the second line names `--number-database-url` instead, since Rails reads a `DATABASE_URL` that names a database over the `database:` of `database.yml`, so numbering `database:` does not split it. A URL that names no database, such as `postgresql://localhost`, takes `database:` from `database.yml`, so the line stays the one above. An SQLite URL at an absolute path, such as `sqlite3:/srv/app/wt1.sqlite3`, names one file for both checkouts, and the flag does not number a file, so the line says `give DATABASE_URL a relative path, as sqlite3:storage/test.sqlite3, so each checkout opens a file under its own root`.

`--number-database-url` fits an app whose worktrees each pass their own `DATABASE_URL`, as from a `.env.test.local` that git ignores and the checkouts lack. Pass the worktree's URL with `--env DATABASE_URL` and add the flag: each checkout then adds its `TEST_ENV_NUMBER` to the database name in the URL, so `postgresql://localhost/app_test_wt1` becomes `app_test_wt1_1` for base and `app_test_wt1_2` for head, apart from every other worktree's too, and no commit's `database.yml` changes. The report prints `numbered_databases app_test_wt1_1 app_test_wt1_2` (`numbered_databases` in `--json`), the names without the rest of the URL. Create them once on the same server, for example `for n in 1 2; do DATABASE_URL=postgresql://localhost/app_test_wt1_$n RAILS_ENV=test bin/rails db:create; done`; when the test helper does not call `ActiveRecord::Migration.maintain_test_schema!`, also pass `--setup 'bin/rails db:create db:schema:load'` so each side loads its own schema. The flag needs `--env DATABASE_URL` and a URL whose path names a database on a server, or `run` exits 1 and says what to change: for an SQLite URL, a relative path instead of the flag. A `database.yml` that reads only in the booted app, such as one that calls `Rails.application`, gives no answer, and the run keeps the processes it would run. On the sample app with PostgreSQL 16 and a change to `db/schema.rb`, six files took 40 to 50 s one at a time and 18 s with numbered databases at a load average of 11 to 18, and 32 s and 9 s at a load average of 2; with `--workers 3` and one shared database, one of two runs reported a `loan_spec.rb#load` row the change did not cause. Before this check, six one-example files took 34 s with `--serial` and 6 to 10 s with numbered databases.

Each checkout has only the files git tracks. An initializer that reads a credential fails there without `config/master.key`, so pass the key: `RAILS_MASTER_KEY=$(cat config/master.key) jitcatch run --env RAILS_MASTER_KEY BASE HEAD TESTS_DIR`.

Each file boots the app once on each side. On the sample app (4 CPUs), six files with one example each took 9.8 s, and one file with the same six examples took 1.9 s. bootsnap starts with an empty cache in each checkout: one file took 3.7 s with it and 2.5 s with `DISABLE_BOOTSNAP=1` passed through `--env DISABLE_BOOTSNAP`, and six files took 8.0 s with it and 9.8 s without it.

### Code that reads a changed value

A change can take effect in code that never calls it by name. A `to_param` reaches every URL a route helper builds for that record, a `default_scope` reaches every query on the model, a constant reaches the SQL it is interpolated into, and a column default reaches every `create` that leaves it out. Those places are not call sites, so `callsites:` cannot list them. `context` lists them under `readers:`, one block per changed value: a method, a scope, a `default_scope`, a constant, a callback, a validation, an `attribute` or `db/schema.rb` column default, or a `config.` setting in `config/`. It reads `app/`, `config/`, `lib/`, and `db/schema.rb` at `HEAD` from git, never from the checkout, and the ERB templates under them as Ruby, line for line. A call in a template is a call site too, so a method that a view calls by name lists the view under `callsites:`, not under `readers:`.

A history of four files:

```text
config/routes.rb                         resources :branches do; resources :closures, only: :index; end
app/controllers/closures_controller.rb   before_action :set_branch ... @branch = Branch.find(params[:branch_id])
app/views/branches/show.html.erb         <%= link_to "Closures", branch_closures_path(@branch) %>
app/models/branch.rb (head adds)         def to_param; code; end
```

`context base HEAD` prints:

```text
    callsites: (none by name; 1 under readers:)
```

```text
readers: 1 for 1 changed value
  Branch#to_param (added) method m01 aac7821:app/models/branch.rb:4 readers=1
    100 route_param_mismatch aac7821:app/views/branches/show.html.erb:2
      rank: the URL value and the lookup now disagree
      why: @branch goes through Branch#to_param (now `code`) into params[:branch_id]; ClosuresController#index reads params[:branch_id] by id (Branch.find(params[:branch_id]), app/controllers/closures_controller.rb:11)
      test: Render app/views/branches/show.html.erb:2 with a Branch whose to_param differs from its id, follow the URL branch_closures_path(@branch) builds, and check ClosuresController#index finds that same Branch.
  not seen: receivers named unlike their model (`x = Branch.first; link_to x`); dispatch names built at run time from data outside the source (a DB column, a request param); routes drawn by `draw`, loops, or concerns; `to_param` reached through a gem's helper; serializers, jbuilder, and other template languages than ERB; callbacks and validations added by concerns or gems; config read through ENV or a YAML file at boot
```

A row is the place (`commit:path:line`, which `git show` takes), how it reads the value (`mechanism`), its score, `rank:` (why it scores what it does), `why:` (what the source says), `also:` (more places of the same kind for the same value), and `test:` (what a test would check). `note:` marks a row on a line the change itself edits. Rows go from the highest score down, at most 10 in all; the first line counts the rest, and `--all-readers` prints every one, in the text and in `--json`. A row that a method's `callsites:` already lists, or a plain read inside a method that a constant's `read_by:` already lists, is left out. `not seen:` names what the reader cannot see: it names a record's model by the name of its variable or method (`@branch`, `home_branch`, `branches`), so `x = Branch.first; link_to x` is not listed. A history with no `app/`, `config/routes.rb`, or `config/application.rb`, such as a gem's, has no models, routes, or templates, so there it names only the two that any Ruby hides.

## Install

`gem install jitcatch` installs the `jitcatch` command. In an app with a `Gemfile`, add the gem to the `:development, :test` group instead, as the [Quick start](#quick-start-in-your-rails-app) shows, and run `bundle exec jitcatch`. It has no runtime dependency. A checkout of this repository works too: put its `bin` directory on `PATH`.

Install the skill with the [`skills`](https://github.com/vercel-labs/skills) CLI (Node.js 22.20 or newer). This repository is private, so the command needs GitHub access through a Git credential, the GitHub CLI, or SSH.

```sh
npx skills add meganemura/jitcatch
```

Select this skill, install it globally, or target one agent:

```sh
npx skills add meganemura/jitcatch --skill jitcatch
npx skills add meganemura/jitcatch -g
npx skills add meganemura/jitcatch -a cursor
npx skills add meganemura/jitcatch -a claude-code
```

Add `-y` to skip prompts. The skill runs the `jitcatch` command, so install the gem as well.

Without the CLI, copy or symlink `skills/jitcatch` into the agent's skills directory, for example `.agents/skills/`, `.claude/skills/`, or `.cursor/skills/`.

## Limits

- A call site counts only when the source names its receiver's class: a call on `self` (or with no receiver), on a constant (`Cart.build`), on `self.class`, on `new` of one of those, on an instance variable that the class assigns only from one `Const.new`, or on a local variable that every assignment in its method sets from the same `Const.new` (`repo = Repo.new; repo.read`). A value the source does not type goes to the class Rails names it after, when that class defines the method: a parameter or a block parameter (`loan.approve` in `Gate#check(loan)`), a local that no assignment sets from a `Const.new`, and an instance variable that none sets (`@loan = loan`), all as a `Loan`. A reader that `belongs_to :borrower` or `has_one :borrower` declares reads a `Borrower`, or the class its `class_name:` string names, so `borrower.approved_cents` inside `Loan#approve` calls `Borrower#approved_cents`; a polymorphic one reads no class. A name that disagrees with a `Const.new` the method or class assigns to it names no class. A call on what a method of the same class returns, as in `emitter_for(format).render`, goes to each constant that method can return, when it returns only constants and nil (through `case`, `if`, and the ternary). A call on a local assigned two different constants, on a name that names no class, or on any other return value makes no edge, so `reachable_from` can miss a caller. Such a call is listed under `dynamic_callers:` of each changed method whose name, or the name of a method in its `reachable_from`, it sends, as `Emit.looked_up (render)`. An instance method of a class whose name ends in `Controller` is left out of those names, since the router calls a controller action and no code in the app sends its name, so `cipher.update` is not listed when `ThingsController#update` reaches the change. A call on a local that holds only a block is left out too: a `&block` parameter, or a local that every assignment in its method sets to `-> {}`, `lambda {}`, `proc {}`, or `Proc.new {}`. Its `call` or `.()` runs that block, never a method of the repository. A `call` on a parameter, such as `job.call` in `def sync(job)`, is still listed. A call on `self` that its class does not define goes to the one indexed method of that name, for a method from a module or a superclass. From an instance method, only an instance method counts. A name the class declares with `attr_reader`, `attr_writer`, or `attr_accessor` goes to that reader or writer. `Const.new`, and `new` called with no receiver in a class method, also goes to that class's `initialize`, or to the nearest one up its superclass chain, so the callers of `Runner.new` reach `Runner#initialize` and what it calls. A superclass is looked up from outside the class it heads, as Ruby does, so `class Error < Error` inside `module Shop` names the outer `Error`. `reachable_from` keeps callers up to four calls away, and the hop from `new` into `initialize` is not one of the four. It keeps the eight nearest. `reached_by` in `--json` holds every caller at any depth, with no cap (`caller_depths` maps each to the fewest calls between them), and `run` reads it for the mentions and the related id, so a test that enters high, such as a request spec through a controller and a service or a CLI test that calls `CLI.start`, still names a changed method five or more calls down. Such a test reaches most changed methods, so its row is usually `related:guess` with that method in the list. `create`, `create!`, and `build` go there too when the class's superclass chain in the repository reaches `ActiveRecord::Base` (`class Post < ApplicationRecord`), since Active Record defines them to call `new`. On any other class they make no edge, since the code that defines them is not in the index. A class method of the same name up the chain takes the call instead.
- `define_method` and `class_eval` are not indexed. A definition with a receiver other than `def self.foo` is coarse.
- A rename is a deletion plus an addition (`git diff --no-renames`).
- Coverage is not collected. `--coverage` only reads the JSON you pass.
- The discard rules do not decide intended versus regression.
- If the candidate tests never state the old behavior, a regression in that gap stays at `reported` 0.
- A test of a new feature fails on base and is not a candidate.
- The related id can sit one step away from the line that caused the failure.
- A mention is a method call, a constant, or a symbol in that test method or in a method of the same file that it calls, directly or through other such methods. `Owner.new` mentions the `initialize` of the class whose name ends in `Owner`, and `mentions` lists it as the test writes it. `A::Owner.new` mentions only a class whose name ends in `A::Owner`, so it does not name `B::Owner#initialize`. A call in the changed constructor's `built_by:` mentions it the same way: `Loan.create!` on an Active Record model, or a FactoryBot call (`create(:loan)`, `build(:loan)`, `create_list(:loan, 2)`, `build_stubbed(:loan)`), which `mentions` lists as `create(:loan)` for a call that saves (`create`, `create_list`, `create_pair`) and as `build(:loan)` for one that does not. A file that defines its own method of that name calls that method, not FactoryBot, and `attributes_for` builds no object. A call sent to a class the test names, or to an instance the test builds with `.new`, is also listed with that class, as `Index.parse` or `Cart#total`. Among changed methods of one name, the related id is then the one on that class (or on a class whose name ends in it), unless none is, as for a method a superclass defines. A method name the test sends only to constants the repository does not define, as in `File.write(path, text)` or `Dir.mktmpdir`, is not a mention, so `File.write` does not name a changed method reached from `Emitter.write`. `emitter.send(:write)` sends `write` to `emitter`, so a test that writes both still mentions `write`. A `send`, `__send__`, or `public_send` with a literal name is read as a call of that name in the code too, so `send(:helper)` in a method reaches `helper`. Words in strings and comments are not mentions, except a method name passed as a plain string to `send`, `public_send`, `method`, or `respond_to?`, as in `send("total")`. A symbol that keys a Hash, as in `snap[:total]`, `snap.fetch(:total)`, or `{ total: 1 }`, is not a mention. A call to `message`, `full_message`, or `detailed_message` also mentions `to_s`, which an error class overrides to build its message. A string shaped like a relative path (`"exe/tool"`, `"../bin/x"`) that names a file of head, read from the repository root, from the candidate's directory, or as `File.expand_path` reads it next to the candidate, is a script the test may start in another process: the names in that file count as mentions too. A string that an assertion or a matcher compares directly, as `assert_includes error.backtrace.first, "lib/tool/model.rb"` or `include("lib/x.rb")`, is expected text and names no script. A helper in another file is not read.
- Files run one at a time unless you pass `--workers`. The base run and the head run of one file run at the same time, each in its own worktree, so a test that writes a fixed path outside the worktree or listens on a fixed port can collide with its other side, and with other files under `--workers`. Pass `--serial` for such files. The repository's existing suite is not run. The repository has to be able to add worktrees.
- An assertion backtrace usually stops in the test, so a library line is found from names the test mentions.
- An RSpec example's mentions come from its own block, the `let`, `subject`, and hook blocks of the groups around it, those groups' arguments, and the same-file helpers they call. A group described as `"#total"` or `".build"` names that method, and `described_class.new` names `Owner.new`. `described_class.parse` is listed as `Owner.parse`. A `let(:result)` or `subject(:result)` name is the spec's own helper, so neither it nor a bare `result` call mentions a changed method `result`. When its block builds one class, as `let(:cart) { Cart.new }` does, `cart.total` is listed as `Cart#total`. An implicit `subject`, a shared example group, and a helper in `spec/support` are not read; an example from a shared group defined in another file reads the whole candidate file.
- Base and head of a Rails app on a database server share one test database unless `config/database.yml` names it with `TEST_ENV_NUMBER` on both revisions; `run` then runs one process at a time (see Rails apps). It cannot tell when `database.yml` reads only in the booted app. MySQL was not run; its shared name was tested only through Active Record's reading of `database.yml`. The suite tests only the shape of a Rails project; the Rails recipe was measured on a Rails 8.1 app with PostgreSQL 16 and SQLite.
- An RSpec error outside every example, such as in an `after(:suite)` hook, is reported only when no example ran.

## Development

```sh
ruby -Ilib test/run.rb
```

The engine tests build temporary git repositories and cover context, execution, flakes, timeouts, and signature-change discards. `test/jitcatch/test_shop_demo.rb` rebuilds the shop fixture and compares `context` and `run` with `examples/runs/*/context.txt` and `run.txt`, byte for byte.

## License

MIT

---

[Japanese](README.ja.md)
