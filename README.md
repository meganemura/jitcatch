# jitcatch

jitcatch keeps the Ruby tests that pass on the parent of a change and fail on the change.

A coding agent reviewing a change writes tests for that diff. A test that only describes the new behavior fails on the parent and is not evidence of a regression. A test the parent already passes, and that fails on the change, shows a claim the old code satisfied and the new code does not. jitcatch runs the tests on both revisions, drops flakes and a few other non-signals, and prints what is left.

The method follows Meta's catching JiT tests ([Harden and Catch](https://arxiv.org/abs/2504.16472); [Just-in-Time Catching Test Generation at Meta](https://arxiv.org/abs/2601.22832)).

## Usage

Ruby 3.3 or newer. No gems. `minitest` and `prism` ship with Ruby. RSpec candidates need `rspec-core` where they run: in the project's bundle, or installed for that Ruby when the project has no `Gemfile`. `BASE` is the parent revision and `HEAD` is the change. Each must resolve to a commit. Uncommitted files are not in the diff.

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
    related guess: m05 of m02,m04,m05
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

The full text is `examples/runs/intended/context.txt` and `examples/runs/intended/run.txt`. Both reported rows are intended: the message says orders of 5000 cents or more get 10% off. A test that states the new rule directly fails on base and is not a candidate. That pass-on-base / fail-on-head result has the same shape as the regression run. The commit message is what distinguishes them.

Delete the scratch directory when you are done. Keep a test in the project's suite only when you mean to promote it. A likely-regression test belongs there after the bug is fixed. An intended-change test states the old behavior.

Characterization tests from branchout can be candidates, as Minitest files or as RSpec specs (`--format rspec`). Emit them on a checkout of the base revision with `--require-by-name`, so that each side loads its own worktree's code. A test emitted without it keeps a `require_relative` or an absolute path. That is fine when the path resolves inside the worktree, as for a test emitted under `.jitcatch/` of the checkout. When it points outside the worktree, both sides load the same file and every row is `no_signal`.

On another repository, pass `--repo` when that repository is not the working directory:

```sh
jitcatch context --repo DIR BASE HEAD
jitcatch run --repo DIR BASE HEAD TESTS_DIR
```

### Options

| Flag | Commands | Effect |
| --- | --- | --- |
| `--json` | `context`, `run`, `assess` | Print the same document as JSON. |
| `--repo DIR` | `context`, `run` | Git repository to read. The default is the working directory. |
| `--coverage FILE` | `context` | Replace the grep of existing tests with this file. The JSON has `"format": "jitcatch-coverage-v1"` and a `tests` array. See `examples/coverage/jitcatch-coverage-v1.sample.json`. |
| `--reruns N` | `run` | Extra runs on head after a pass-on-base / fail-on-head result. The default is 2. `0` skips the flake check. |
| `--timeout SEC` | `run` | Seconds before a test file is killed. The default is 10. The minimum is 1. |
| `--workers N` | `run` | Test files that run at the same time, each worker in its own base and head worktrees. The default is 1. Each worker runs two Ruby processes at once, so more workers help only while CPUs are idle. The report is the same for every N. |
| `--serial` | `run` | Runs one Ruby process at a time: a file's base run, then its head run. For candidates that write a fixed path outside the worktree or listen on a fixed port. It takes no `--workers` above 1. The text report prints `serial` and `--json` records `"serial": true`. |
| `--env NAME` | `run` | Pass this variable from your environment to the test processes. Repeat it for more names. The run records the names, not the values, and lists a name that is not set on an `env_unset` line. |

| Command | Arguments |
| --- | --- |
| `jitcatch context` | `BASE HEAD` |
| `jitcatch run` | `BASE HEAD TESTS_DIR` |
| `jitcatch assess` | `RUN.json`, the file written by `run --json` |

To review the first commit, pass `ROOT^` as `BASE`. The parent of a root commit is read as the empty tree.

When `BASE` is not an ancestor of `HEAD`, the diff also undoes the commits only `BASE` has. `context` and `run` then print a `warning:` line under `head` that counts those commits and names the merge base to pass as `BASE` instead. When the two resolve to the same commit, the `warning:` line says so.

`assess` reprints the run's warnings, the counts, and the candidate rows. It applies the same rules as `run`. A row shows the first line of the failure, or the expected and actual lines of a Minitest diff. When one of those is longer than 100 characters, the row shows the Hash entries or the Array elements that differ, or a window around the first column that differs with a `^ column N` marker. The marker shows only when the added line replaces the removed one: two lines from different places of the diff are each cut to 61 characters. A failed `assert_raises(X)` also shows Minitest's `Class:` and `Message:` lines, which name the error that came instead. An error row that was raised from another error adds that error's class and message, as `cause: KeyError: key not found`. RSpec prints the cause itself. Minitest does not, so jitcatch loads `lib/jitcatch/minitest_cause.rb` into each Minitest candidate's process with `-r`, which adds the cause to Minitest's error text; the `rerun:` line does not load it. A row line longer than 300 characters, such as a whole frozen Array in a `FrozenError`, is cut there and ends with `... (+N more; the whole message is in --json)`. `--json` keeps the whole message.

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
| 3 | `run` stopped with no rows: a side failed its setup check, or no candidate file loaded on either side. |

### Results

| Bucket | Meaning |
| --- | --- |
| `no_signal` | Passed on base and on head. |
| `fail_on_base` | The parent did not satisfy the test. Often the test only describes a new feature. The text report prints what base did under the row, as `base: error NoMethodError undefined method 'apply_coupon' for an instance of Shop::Cart`. |
| `flaky` | Passed on base, failed on head, then a rerun did not fail the same way. Dropped. |
| `discarded` | Passed on base and failed on head, then a rule removed it. Still listed under `assess:`. |
| `reported` | Passed on base and failed on head, and no rule removed it. Judge this row. |

`generated` counts test methods. `candidates` counts stable pass-on-base / fail-on-head tests before the discard rules. `reported` is what remains.

A tag is a hint, not the judgment. `touches:changed_method` means the test names a method the diff changed. `Owner.new` names the `initialize` of that owner alone (`Mismatch.new` is not `Spec#initialize`), and a changed constructor is the related method only when the test names no other changed method and goes through no changed method's caller. `touches:changed_constant` means it names a constant the diff changed. `touches:changed_dependency` means the error came from inside a gem whose locked version changed. An error that starts inside any gem does not get `touches:changed_method`. `touches:unchanged_caller` means the test goes through an entry point the diff did not edit, and that entry point reaches a changed method. `discard:signature_change`, `discard:load_error`, `discard:timeout`, and `discard:no_database` name the rule that removed a candidate. `discard:signature_change` applies only when the test itself makes the call that a removed method or a new signature broke. When unchanged code makes it, such as `class B < A` still calling the `A#helper` that head removed, the row is reported with `caller:unchanged:lib/b.rb:5`, the line of that call (`caller:changed:` for a line the diff wrote or a line in a changed method; `changed_lines` in `--json` lists the head lines each file's hunks wrote). The related id (`m05`, or `-` when there is none) is the downstream changed method when several changed methods sit on the path. When the failure's backtrace runs through changed methods, it is the innermost of them, and that pick is not a guess: the outer frames only called it. A frame's line is read as a line of head, so it never hits the method that held that line on base. `related:guess` means the evidence that picked the id points at more than one changed method, as when the test names only an unchanged caller that reaches several; the row's next line, `related guess: m05 of m02,m04,m05`, lists them all, and `method_ids` holds them in `--json`. The pick prefers a method that existed on base over one the diff added, except over an edit that only adds a call to an added method (`forwards_to_added` in `--json`), as `net - volume` becoming `net - volume - coupon(n)` does: the new value comes from the added method. `related:dynamic` means no changed method is related, but the test calls a method from `dynamic_callers:`; the row's next line says so, as in `related: none, Emit.looked_up sends render to a receiver the source does not name`.

## How it filters

`context` diffs the two revisions and maps hunks onto methods with Prism. Changed methods are `m01`, `m02`, and so on. When `Gemfile.lock` changed, a `dependencies:` block lists each gem as `gem old -> new`. A changed constant is `k01`. A class or module that only one side defines anywhere is a constant too, `added` or `removed`, shown by its header line. A method that did not itself change but reads that constant is `affected` (`via=k01`). A method that leaves one file while head defines the same name in another file, test files included, is `moved`, shown at its new place with `moved_from=` naming the old file; when several files define it, one the diff touched comes first. A constant that moves the same way with the same value is `moved` with `moved_from=` too, and a method that reads it is not `affected`. A constant that moved and took a new value is `modified`, with `moved_from=`. A reader or writer from `attr_reader`, `attr_writer`, `attr_accessor`, or a `Struct.new` or `Data.define` member list is a method, with the one-name form (`attr_reader :seed`) as its source, so a name dropped from such a line is `removed` and the names left on it do not change. A list given as `*FIELDS` counts when the same file set `FIELDS` to a list of symbols before it, as in `FIELDS = %i[x y].freeze`; each member then takes the line of its symbol in that list. A `def` or reader inside a conditional of the class body (`attr_reader :x if cond`) counts. The branches read as if each ran in order, so a bare `private` in a branch carries past the conditional. A definition in a Concern's `included do`, `prepended do`, or `class_methods do` block counts too. Each method block has the old and new source, call sites in the library, the entry points that reach it (`reachable_from`), and existing tests that mention it. A changed `initialize` also shows `built_by:`, the calls besides `new` that run it: `create`, `create!`, and `build` on an Active Record model, and `build(:loan)` and `create(:loan)` for each FactoryBot factory that builds the class. Its `tests:` line lists each test file that calls one of those or `Owner.new`, with the calls it makes (`spec/models/loan_spec.rb via create(:loan)`). No test calls `initialize` by that name, so a constructor gets no grep hits. Factories are read from `spec/factories` and `test/factories` without loading them: the class comes from `class:` (a constant, a string, or a symbol), then from the parent (`parent:`, or the factory it nests in), then from the camelized name, and an alias in `aliases:` builds the same class. A factory also counts for each class its associations build, through their own associations too: a bare `borrower` that names a factory, `association :borrower` (or `factory: :user`), or an attribute block that calls `association`, in the factory or one it inherits from, so `create(:loan)` saves a `Borrower` too. An association in a trait is not followed. A factory whose class the source does not settle is not followed and is listed under `factories_skipped:` with the reason: a `class:` computed at run time, a parent that is not a factory read there, or a class that no file defines, which an inflection the app configures can cause (`ApiKey` against `APIKey`). A method that an Active Record model's class body names in a callback or a validation (`after_save :count_save`, `validate :check`, or an `if:` or `unless:` of either, as in `validates :amount, presence: true, if: :checked?`) shows `run_by:`, the calls that run it by Rails's rules, followed by the lines that name it. A save callback lists `Loan.create`, `Loan.create!`, `Loan#save`, `Loan#save!`, `Loan#update`, and `Loan#update!` (a create callback leaves out the updates, an update callback the creates), with `create(:loan)` and `build(:loan)` for each factory of the class. A validation adds `Loan#valid?`, `Loan#invalid?`, `Loan#validate`, and `Loan#validate!`. An `on:` on a validation or on a commit or rollback callback keeps only the calls of that context, and the line shows it: `before_validation :mark_pending, on: :create` lists no update, so a method that calls `update!` does not reach it, and `on: :update` lists no create and no factory. A context of the app's own (`on: :publish`) runs only from a call that takes one, so it lists `Loan#save`, `Loan#save!`, and the four validation calls. An `on:` that is not written as symbols narrows nothing. A destroy callback lists `Loan#destroy` and `Loan#destroy!`. A method that such a callback reaches (`reachable_from`) gets the same line. A method outside the tests that makes one of those calls, as the source writes it (`Loan.create!` in `LoanDesk.open`, or `update!` inside a method of `Loan`), joins `reachable_from` with its own callers, so a test that calls `LoanDesk.open` names the callback. Its `tests:` lists each test file that makes one of those calls (`spec/models/loan_spec.rb via Loan.create!`), next to the grep hits, and `run` counts the call as a mention of the method. `Loan#save` counts when the test's source settles the record's class (`loan = Loan.new`). `build(:loan)` does not save, so it counts only in a test that also makes one of the record calls the callback lists, as in `build(:loan).save!` or `expect(build(:loan)).to be_valid`, where `be_valid` calls `valid?`. That call's receiver is not checked, since a local the source does not type holds the built record, so a test that saves another record next to `build(:loan)` counts too. A test that only builds gets no `tests:` hit and no mention in `run`. A callback line in a Concern, one a parent class declares, and a call on a subclass are not followed. When no test mentions it, `entry_point_tests` lists the test files that name the class of a public entry point in `reachable_from` and call a method of that entry point's name. `--coverage` uses the line lists in the JSON file instead of the grep. The brief ends with one `entrypoints <Const>:` section for each class or module that holds a changed method. It lists that class's public methods on head (on base when head has none), changed ones first with their change kind, then the rest as `unchanged`, at most 12, with the ones that reach a changed method first and `(+N more)` for the methods left out. A class that defines `initialize` on either side shows `Owner.new` with the role of `Owner#initialize` in its place. These are the methods a test can call, and `run` counts their names as mentions.

`run` adds a git worktree for each revision, copies the scratch directory to `.jitcatch/` in that worktree, and runs each file in its own process:

```sh
ruby -Ilib -I. -r<jitcatch>/lib/jitcatch/minitest_cause.rb .jitcatch/<file> -v --seed 1
ruby -Ilib -I. -e 'require "rspec/core"; exit(RSpec::Core::Runner.run(ARGV))' -- \
  --format json --out .jitcatch-report.json --seed 1 --backtrace --no-color .jitcatch/<file>_spec.rb
```

A file named `*_spec.rb` runs with RSpec, unless it requires `minitest` (a minitest/spec file). RSpec reads the worktree's `.rspec`, so `--require spec_helper` there still loads, and puts `spec/` on the load path. The formatter given on the command line replaces the ones `.rspec` names. One example is one row, named by its full description (`Cart#total sums the prices`), and the text report shows its line (`cart_spec.rb:11`). An expectation failure is `fail`, any other error is `error`, and `pending` is `skip`. An error while RSpec loads the file is one `<file>#load` row, as for Minitest.

When a revision has a `Gemfile`, its files run with `-rbundler/setup` and `BUNDLE_GEMFILE` set to that `Gemfile`, so each side loads the gems its own lock names. Each side also gets the checkout's `.bundle/config` (the settings `bundle config set --local` writes, such as `BUNDLE_WITHOUT`), which git does not track; a relative `BUNDLE_PATH` keeps naming the checkout's directory. Before any test runs, `run` checks once per side that the side can load its bundle and the test framework (`minitest` for a Minitest candidate, `rspec-core` for an RSpec candidate). Without a `Gemfile`, the check asks the Ruby that runs jitcatch for the framework. A successful run prints `bundle base ok` for each side that has a `Gemfile`. When a side fails the check, for example because a locked gem is not installed, every candidate would fail to load there and read as `fail_on_base` or as a regression. So `run` stops with exit status 3 and names each failed side, the command that failed, and the last lines of its stderr:

```text
jitcatch: setup failed, so no test ran; a test cannot pass or fail on a side that cannot load
base <sha>
head <sha>
setup head failed: ruby -e 'require "bundler/setup"; require "minitest"'
  Could not find gem 'jitcatch_absent_gem (= 9.9.9)' in locally installed gems.
  not passed: BUNDLE_WITHOUT (add --env BUNDLE_WITHOUT)
Run that command in a checkout of that side, fix what it says (often `bundle install` there), and run jitcatch again.
```

A side can pass that check and still fail to boot what every candidate requires, such as a Rails app whose test database does not exist. When every file is a `<file>#load` row that errored on both sides, no row can tell base from head, so `run` stops with exit status 3 too. The first line is then `jitcatch: every candidate file failed to load on both sides, so no row can tell base from head`, and each side has a `load base failed:` line with the first file's rerun command and the error under it.

The text goes to stderr. With `--json`, stdout holds `{"command": "run", "error": "setup_failed", "stage", "base", "head", "setup_failed": [{"side", "commit", "command", "stderr", "not_passed"}]}` instead, where `stage` is `setup` or `load`. `assess` refuses that document. The process keeps only a fixed list of environment variables and the ones named with `--env`. A failed side names each Bundler setting (`BUNDLE_WITHOUT`, `BUNDLE_PATH`, and other `BUNDLE_` variables) set in your environment that `--env` did not pass, on the `not passed:` line (`not_passed` in `--json`).

Files named `*_test.rb`, `test_*.rb`, or `*_spec.rb` run. When none have those names, every `.rb` file runs. At most 40 files run. A test that passes on base and fails, errors, or times out on head is a candidate. So is one that times out on base and does not pass on head, since base might pass with more time; the timeout rule below discards it. `--reruns` repeats candidates on head. One disagreement makes the test `flaky`. The comparison reads the whole failure message. It masks the name directly under the temp directory, an object address (`#<Class:0x00007f...>`), and a time of day with its date (`created_at: "2026-11-04 19:02:03.212197000 +0000"`), so a `Dir.mktmpdir` path, a new anonymous class, or the time a record was saved in a message is not a disagreement. A date alone is not masked. The rerun line shows the first message line that moved. The text report prints each rerun under a `flaky` row, and the JSON row keeps them in `reruns`. A timeout is not rerun.

Four rules then turn a candidate into `discarded`: a `LoadError` on head, a timeout on either side, an Active Record error on head that says its database does not exist or cannot be reached (`NoDatabaseError`, `ConnectionNotEstablished`, `DatabaseConnectionError`), or a `NameError`, `NoMethodError`, or arity `ArgumentError` on a name the diff removed or whose signature it rewrote. A removed class or module counts as a removed name. An arity `ArgumentError` is `wrong number of arguments`, `missing keyword`, `unknown keyword`, or `struct size differs` (a `Struct` given more values than its members), also when `assert_raises` or RSpec's `raise_error` caught it and failed. An `ArgumentError` the code raises on purpose, such as `qty must be > 0`, stays `reported`.

The same repository and the same tests produce the same bytes. Order is fixed, the text has no timestamps, and a worktree's absolute root is written as `{worktree}` in a message (as in `{worktree}/lib/cart.rb`, and for `Dir.pwd` alone) and dropped from a backtrace frame. A message names the tests directory where it named the copy at `{worktree}/.jitcatch`, as the rerun line does: `{worktree}/candidates/fixtures/a.json` for `TESTS_DIR` `candidates/` inside the repository, and `{worktree}/../catch/tests/fixtures/a.json` for `../catch/tests` outside it. A backtrace frame in a test names `TESTS_DIR` the same way, without `{worktree}/`: `candidates/cart_test.rb`, or `../catch/tests/cart_test.rb`. The run's `--json` names that path as `tests_dir`, and `assess` reads a frame under it as the test's own. A relative `.jitcatch/`, such as `__FILE__`, stays as printed, since it cannot be told apart from text a test compares. Ruby's own prefix is written as `{ruby}/`.

Each candidate row under `assess:` ends with a `rerun:` line, and every `--json` row has `rerun`. It runs that one test again from the repository root on the checkout you have, with the candidate named by its path from the repository root, outside the repository too (`../catch/tests/cart_test.rb`), so the line names no directory of one machine. The run loads each candidate from a copy of `TESTS_DIR` at the root of each checkout, so a `require_relative` that leaves `TESTS_DIR` names a file of the checkout there, but from the rerun line it names the file beside `TESTS_DIR`. When the two differ, which happens unless `TESTS_DIR` sits directly under the root, `run` prints a `warning:` that names the line and both files (`a_test.rb:2 require_relative "../lib/a" loads lib/a.rb in the run but ../base/lib/a.rb from the rerun line`). Load the repository's code with `require` and the rerun line's `-I` instead. The line runs in your shell, where every variable `--env` passed came from, so it sees them too, and it holds no values. For example: `ruby -Ilib -I. -e 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))' candidates/cart_spec.rb:11`, or `ruby -Ilib -I. candidates/cart_test.rb -n CartTest#test_total`, behind `bundle exec` when head has a `Gemfile`. A `<file>#load` or `<file>#timeout` row reruns the whole file. The RSpec line is not plain `rspec`: `rspec` puts `lib/` of the nearest directory that holds `spec/` first on the load path, so a checkout under a Rails app's `tmp/` would load the app's `lib/`. The line pins that directory to the working directory, and the run does the same in its worktrees. When head holds `spec` at its root, as a Rails app does, RSpec already finds that root, so the line leaves out the pin (`RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); `), the one part that sets rspec-core's private state. It also lifts RSpec's 200-character cut on a printed object, so a `raise_error` row shows the whole error it got.

## Rails apps

Candidates for a Rails app are RSpec files that start with `require "rails_helper"`, as the app's specs do, or Minitest files that start with `require "test/test_helper"`. They can use the app's factories and its test database. `context` follows a factory to the class it builds, so `create(:loan)` names `Loan#initialize`.

Base and head boot the app at the same time. SQLite at a relative path (the Rails default `storage/test.sqlite3`) is a file in each worktree, so the two sides never meet. A database server, such as PostgreSQL or MySQL, has one test database name for both sides, and each side loads its own `db/schema.rb` into it while the other side runs. On a change that removed a column, 1 to 6 of 6 candidates came back as `reported` load errors (`bin/rails aborted!`). jitcatch sets `TEST_ENV_NUMBER` in each checkout, the variable parallel_tests sets: `1` and `2` for base and head of the first worker, `3` and `4` for the second, and so on. When `config/database.yml` on both revisions names the test database with it, each checkout uses its own database, and the same run reported none:

```yaml
test:
  <<: *default
  database: app_test<%= ENV["TEST_ENV_NUMBER"] %>
```

Create the databases once, two for each worker, before the first run. Rails loads each revision's schema when it boots:

```sh
for n in 1 2; do RAILS_ENV=test TEST_ENV_NUMBER=$n bin/rails db:create; done
```

When head's database is missing, its rows are `discard:no_database`. When `database.yml` does not use the variable, pass `--serial`, so that one process runs at a time. On the sample app, six files took 34 s with `--serial` and 6 to 10 s with numbered databases.

Each checkout has only the files git tracks. An initializer that reads a credential fails there without `config/master.key`, so pass the key: `RAILS_MASTER_KEY=$(cat config/master.key) jitcatch run --env RAILS_MASTER_KEY BASE HEAD TESTS_DIR`.

Each file boots the app once on each side. On the sample app (4 CPUs), six files with one example each took 9.8 s, and one file with the same six examples took 1.9 s. bootsnap starts with an empty cache in each checkout: one file took 3.7 s with it and 2.5 s with `DISABLE_BOOTSNAP=1` passed through `--env DISABLE_BOOTSNAP`, and six files took 8.0 s with it and 9.8 s without it.

## Install

The program is `bin/jitcatch` in a checkout of this repository. Put that directory on `PATH`.

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

Add `-y` to skip prompts. Put `bin/jitcatch` on `PATH` as well.

Without the CLI, copy or symlink `skills/jitcatch` into the agent's skills directory, for example `.agents/skills/`, `.claude/skills/`, or `.cursor/skills/`.

## Limits

- A call site counts only when the source names its receiver's class: a call on `self` (or with no receiver), on a constant (`Cart.build`), on `self.class`, on `new` of one of those, on an instance variable that the class assigns only from one `Const.new`, or on a local variable that every assignment in its method sets from the same `Const.new` (`repo = Repo.new; repo.read`). A call on what a method of the same class returns, as in `emitter_for(format).render`, goes to each constant that method can return, when it returns only constants and nil (through `case`, `if`, and the ternary). A call on a parameter, on a local assigned anything else, or on any other return value makes no edge, so `reachable_from` can miss a caller. Such a call is listed under `dynamic_callers:` of each changed method whose name, or the name of a method in its `reachable_from`, it sends, as `Emit.looked_up (render)`. A call on `self` that its class does not define goes to the one indexed method of that name, for a method from a module or a superclass. From an instance method, only an instance method counts. A name the class declares with `attr_reader`, `attr_writer`, or `attr_accessor` goes to that reader or writer. `Const.new`, and `new` called with no receiver in a class method, also goes to that class's `initialize`, or to the nearest one up its superclass chain, so the callers of `Runner.new` reach `Runner#initialize` and what it calls. A superclass is looked up from outside the class it heads, as Ruby does, so `class Error < Error` inside `module Shop` names the outer `Error`. `reachable_from` keeps callers up to four calls away, and the hop from `new` into `initialize` is not one of the four. `create`, `create!`, and `build` go there too when the class's superclass chain in the repository reaches `ActiveRecord::Base` (`class Post < ApplicationRecord`), since Active Record defines them to call `new`. On any other class they make no edge, since the code that defines them is not in the index. A class method of the same name up the chain takes the call instead.
- `define_method` and `class_eval` are not indexed. A definition with a receiver other than `def self.foo` is coarse.
- A rename is a deletion plus an addition (`git diff --no-renames`).
- Coverage is not collected. `--coverage` only reads the JSON you pass.
- The discard rules do not decide intended versus regression.
- If the candidate tests never state the old behavior, a regression in that gap stays at `reported` 0.
- A test of a new feature fails on base and is not a candidate.
- The related id can sit one step away from the line that caused the failure.
- A mention is a method call, a constant, or a symbol in that test method or in a method of the same file that it calls, directly or through other such methods. `Owner.new` mentions the `initialize` of the class whose name ends in `Owner`, and `mentions` lists it as the test writes it. `A::Owner.new` mentions only a class whose name ends in `A::Owner`, so it does not name `B::Owner#initialize`. A call in the changed constructor's `built_by:` mentions it the same way: `Loan.create!` on an Active Record model, or a FactoryBot call (`create(:loan)`, `build(:loan)`, `create_list(:loan, 2)`, `build_stubbed(:loan)`), which `mentions` lists as `create(:loan)` for a call that saves (`create`, `create_list`, `create_pair`) and as `build(:loan)` for one that does not. A file that defines its own method of that name calls that method, not FactoryBot, and `attributes_for` builds no object. A call sent to a class the test names, or to an instance the test builds with `.new`, is also listed with that class, as `Index.parse` or `Cart#total`. Among changed methods of one name, the related id is then the one on that class (or on a class whose name ends in it), unless none is, as for a method a superclass defines. A method name the test sends only to constants the repository does not define, as in `File.write(path, text)` or `Dir.mktmpdir`, is not a mention, so `File.write` does not name a changed method reached from `Emitter.write`. Words in strings and comments are not mentions, except a method name passed as a plain string to `send`, `public_send`, `method`, or `respond_to?`, as in `send("total")`. A symbol that keys a Hash, as in `snap[:total]`, `snap.fetch(:total)`, or `{ total: 1 }`, is not a mention. A call to `message`, `full_message`, or `detailed_message` also mentions `to_s`, which an error class overrides to build its message. A string shaped like a relative path (`"exe/tool"`, `"../bin/x"`) that names a file of head, read from the repository root, from the candidate's directory, or as `File.expand_path` reads it next to the candidate, is a script the test may start in another process: the names in that file count as mentions too. A helper in another file is not read.
- Files run one at a time unless you pass `--workers`. The base run and the head run of one file run at the same time, each in its own worktree, so a test that writes a fixed path outside the worktree or listens on a fixed port can collide with its other side, and with other files under `--workers`. Pass `--serial` for such files. The repository's existing suite is not run. The repository has to be able to add worktrees.
- An assertion backtrace usually stops in the test, so a library line is found from names the test mentions.
- An RSpec example's mentions come from its own block, the `let`, `subject`, and hook blocks of the groups around it, those groups' arguments, and the same-file helpers they call. A group described as `"#total"` or `".build"` names that method, and `described_class.new` names `Owner.new`. `described_class.parse` is listed as `Owner.parse`. A `let(:result)` or `subject(:result)` name is the spec's own helper, so neither it nor a bare `result` call mentions a changed method `result`. When its block builds one class, as `let(:cart) { Cart.new }` does, `cart.total` is listed as `Cart#total`. An implicit `subject`, a shared example group, and a helper in `spec/support` are not read; an example from a shared group defined in another file reads the whole candidate file.
- Base and head of a Rails app on a database server share one test database unless `config/database.yml` names it with `TEST_ENV_NUMBER` on both revisions (see Rails apps). The suite tests only the shape of a Rails project; the Rails recipe was measured on a Rails 8.1 app with PostgreSQL 16 and SQLite.
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
