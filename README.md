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
| `--env NAME` | `run` | Pass this variable from your environment to the test processes. Repeat it for more names. The run records the names, not the values, and lists a name that is not set on an `env_unset` line. |

| Command | Arguments |
| --- | --- |
| `jitcatch context` | `BASE HEAD` |
| `jitcatch run` | `BASE HEAD TESTS_DIR` |
| `jitcatch assess` | `RUN.json`, the file written by `run --json` |

To review the first commit, pass `ROOT^` as `BASE`. The parent of a root commit is read as the empty tree.

When `BASE` is not an ancestor of `HEAD`, the diff also undoes the commits only `BASE` has. `context` and `run` then print a `warning:` line under `head` that counts those commits and names the merge base to pass as `BASE` instead. When the two resolve to the same commit, the `warning:` line says so.

`assess` reprints the run's warnings, the counts, and the candidate rows. It applies the same rules as `run`. A row shows the first line of the failure, or the expected and actual lines of a Minitest diff. When one of those is longer than 100 characters, the row shows the Hash entries or the Array elements that differ, or a window around the first column that differs with a `^ column N` marker. The marker shows only when the added line replaces the removed one: two lines from different places of the diff are each cut to 61 characters. A failed `assert_raises(X)` also shows Minitest's `Class:` and `Message:` lines, which name the error that came instead. An RSpec error row that was raised from another error adds that error's class and message, as `cause: KeyError: key not found`. Minitest does not print the cause, so a Minitest row does not show one. `--json` keeps the whole message.

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

### Results

| Bucket | Meaning |
| --- | --- |
| `no_signal` | Passed on base and on head. |
| `fail_on_base` | The parent did not satisfy the test. Often the test only describes a new feature. |
| `flaky` | Passed on base, failed on head, then a rerun did not fail the same way. Dropped. |
| `discarded` | Passed on base and failed on head, then a rule removed it. Still listed under `assess:`. |
| `reported` | Passed on base and failed on head, and no rule removed it. Judge this row. |

`generated` counts test methods. `candidates` counts stable pass-on-base / fail-on-head tests before the discard rules. `reported` is what remains.

A tag is a hint, not the judgment. `touches:changed_method` means the test names a method the diff changed. `Owner.new` names the `initialize` of that owner alone (`Mismatch.new` is not `Spec#initialize`), and a changed constructor is the related method only when the test names no other changed method and goes through no changed method's caller. `touches:changed_constant` means it names a constant the diff changed. `touches:changed_dependency` means the error came from inside a gem whose locked version changed. An error that starts inside any gem does not get `touches:changed_method`. `touches:unchanged_caller` means the test goes through an entry point the diff did not edit, and that entry point reaches a changed method. `discard:signature_change`, `discard:load_error`, and `discard:timeout` name the rule that removed a candidate. `discard:signature_change` applies only when the test itself makes the call that a removed method or a new signature broke. When unchanged code makes it, such as `class B < A` still calling the `A#helper` that head removed, the row is reported with `caller:unchanged:lib/b.rb:5`, the line of that call (`caller:changed:` for a line in a changed method). The related id (`m05`, or `-` when there is none) is the downstream changed method when several changed methods sit on the path. When the failure's backtrace runs through changed methods, it is the innermost of them. `related:guess` means the evidence that picked the id points at more than one changed method, as when the test names only an unchanged caller that reaches several; the row's next line, `related guess: m05 of m02,m04,m05`, lists them all, and `method_ids` holds them in `--json`. `related:dynamic` means no changed method is related, but the test calls a method from `dynamic_callers:`; the row's next line says so, as in `related: none, Emit.looked_up sends render to a receiver the source does not name`.

## How it filters

`context` diffs the two revisions and maps hunks onto methods with Prism. Changed methods are `m01`, `m02`, and so on. When `Gemfile.lock` changed, a `dependencies:` block lists each gem as `gem old -> new`. A changed constant is `k01`. A class or module that only one side defines anywhere is a constant too, `added` or `removed`, shown by its header line. A method that did not itself change but reads that constant is `affected` (`via=k01`). A reader or writer from `attr_reader`, `attr_writer`, `attr_accessor`, or a `Struct.new` or `Data.define` member list is a method, with the one-name form (`attr_reader :seed`) as its source, so a name dropped from such a line is `removed` and the names left on it do not change. A list given as `*FIELDS` counts when the same file set `FIELDS` to a list of symbols before it, as in `FIELDS = %i[x y].freeze`; each member then takes the line of its symbol in that list. A `def` or reader inside a conditional of the class body (`attr_reader :x if cond`) counts. The branches read as if each ran in order, so a bare `private` in a branch carries past the conditional. A definition in a Concern's `included do`, `prepended do`, or `class_methods do` block counts too. Each method block has the old and new source, call sites in the library, the entry points that reach it (`reachable_from`), and existing tests that mention it. When no test mentions it, `entry_point_tests` lists the test files that name the class of a public entry point in `reachable_from` and call a method of that entry point's name. `--coverage` uses the line lists in the JSON file instead of the grep. The brief ends with one `entrypoints <Const>:` section for each class or module that holds a changed method. It lists that class's public methods on head (on base when head has none), changed ones first with their change kind, then the rest as `unchanged`, at most 12, with the ones that reach a changed method first and `(+N more)` for the methods left out. A class that defines `initialize` on either side shows `Owner.new` with the role of `Owner#initialize` in its place. These are the methods a test can call, and `run` counts their names as mentions.

`run` adds a git worktree for each revision, copies the scratch directory to `.jitcatch/` in that worktree, and runs each file in its own process:

```sh
ruby -Ilib -I. .jitcatch/<file> -v --seed 1
ruby -Ilib -I. -e 'require "rspec/core"; exit(RSpec::Core::Runner.run(ARGV))' -- \
  --format json --out .jitcatch-report.json --seed 1 --backtrace --no-color .jitcatch/<file>_spec.rb
```

A file named `*_spec.rb` runs with RSpec, unless it requires `minitest` (a minitest/spec file). RSpec reads the worktree's `.rspec`, so `--require spec_helper` there still loads, and puts `spec/` on the load path. The formatter given on the command line replaces the ones `.rspec` names. One example is one row, named by its full description (`Cart#total sums the prices`), and the text report shows its line (`cart_spec.rb:11`). An expectation failure is `fail`, any other error is `error`, and `pending` is `skip`. An error while RSpec loads the file is one `<file>#load` row, as for Minitest.

When a revision has a `Gemfile`, its files run with `-rbundler/setup` and `BUNDLE_GEMFILE` set to that `Gemfile`, so each side loads the gems its own lock names. Each side also gets the checkout's `.bundle/config` (the settings `bundle config set --local` writes, such as `BUNDLE_WITHOUT`), which git does not track; a relative `BUNDLE_PATH` keeps naming the checkout's directory. `run` checks the bundle once per side and prints `bundle base ok` or `bundle head failed: <message>`, for example when a locked gem is not installed, or the bundle has no `minitest` (for a Minitest candidate) or no `rspec-core` (for an RSpec candidate). The process keeps only a fixed list of environment variables and the ones named with `--env`. A failed side names each Bundler setting (`BUNDLE_WITHOUT`, `BUNDLE_PATH`, and other `BUNDLE_` variables) set in your environment that `--env` did not pass, as in `bundle head failed: <message>; not passed: BUNDLE_WITHOUT (add --env BUNDLE_WITHOUT)`.

Files named `*_test.rb`, `test_*.rb`, or `*_spec.rb` run. When none have those names, every `.rb` file runs. At most 40 files run. A test that passes on base and fails, errors, or times out on head is a candidate. `--reruns` repeats candidates on head. One disagreement makes the test `flaky`. The comparison reads the whole failure message. It masks the name directly under the temp directory and an object address (`#<Class:0x00007f...>`), so a `Dir.mktmpdir` path or a new anonymous class in a message is not a disagreement. The rerun line shows the first message line that moved. The text report prints each rerun under a `flaky` row, and the JSON row keeps them in `reruns`. A timeout is not rerun.

Three rules then turn a candidate into `discarded`: a `LoadError` on head, a timeout, or a `NameError`, `NoMethodError`, or arity `ArgumentError` on a name the diff removed or whose signature it rewrote. A removed class or module counts as a removed name. An arity `ArgumentError` is `wrong number of arguments`, `missing keyword`, or `unknown keyword`, also when `assert_raises` or RSpec's `raise_error` caught it and failed. An `ArgumentError` the code raises on purpose, such as `qty must be > 0`, stays `reported`.

The same repository and the same tests produce the same bytes. Order is fixed, the text has no timestamps, and a worktree's absolute root is written as `{worktree}/` in a message (as in `{worktree}/lib/cart.rb`) and dropped from a backtrace frame. Ruby's own prefix is written as `{ruby}/`.

Each candidate row under `assess:` ends with a `rerun:` line, and every `--json` row has `rerun`. It runs that one test again from the repository root on the checkout you have, with `{tests}/` standing for the `TESTS_DIR` you passed: `ruby -Ilib -I. -e 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))' {tests}/cart_spec.rb:11`, or `ruby -Ilib -I. {tests}/cart_test.rb -n CartTest#test_total`, behind `bundle exec` when head has a `Gemfile`. A `<file>#load` or `<file>#timeout` row reruns the whole file. The RSpec line is not plain `rspec`: `rspec` puts `lib/` of the nearest directory that holds `spec/` first on the load path, so a checkout under a Rails app's `tmp/` would load the app's `lib/`. The line pins that directory to the working directory, and the run does the same in its worktrees. It also lifts RSpec's 200-character cut on a printed object, so a `raise_error` row shows the whole error it got.

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

- A call site counts only when the source names its receiver's class: a call on `self` (or with no receiver), on a constant (`Cart.build`), on `self.class`, on `new` of one of those, on an instance variable that the class assigns only from one `Const.new`, or on a local variable that every assignment in its method sets from the same `Const.new` (`repo = Repo.new; repo.read`). A call on what a method of the same class returns, as in `emitter_for(format).render`, goes to each constant that method can return, when it returns only constants and nil (through `case`, `if`, and the ternary). A call on a parameter, on a local assigned anything else, or on any other return value makes no edge, so `reachable_from` can miss a caller. Such a call is listed under `dynamic_callers:` of each changed method whose name, or the name of a method in its `reachable_from`, it sends, as `Emit.looked_up (render)`. A call on `self` that its class does not define goes to the one indexed method of that name, for a method from a module or a superclass. From an instance method, only an instance method counts. A name the class declares with `attr_reader`, `attr_writer`, or `attr_accessor` goes to that reader or writer.
- `define_method` and `class_eval` are not indexed. A definition with a receiver other than `def self.foo` is coarse.
- A rename is a deletion plus an addition (`git diff --no-renames`).
- Coverage is not collected. `--coverage` only reads the JSON you pass.
- The discard rules do not decide intended versus regression.
- If the candidate tests never state the old behavior, a regression in that gap stays at `reported` 0.
- A test of a new feature fails on base and is not a candidate.
- The related id can sit one step away from the line that caused the failure.
- A mention is a method call, a constant, or a symbol in that test method or in a method of the same file that it calls, directly or through other such methods. `Owner.new` mentions the `initialize` of the class whose name ends in `Owner`, and `mentions` lists it as the test writes it. `A::Owner.new` mentions only a class whose name ends in `A::Owner`, so it does not name `B::Owner#initialize`. A call sent to a class the test names, or to an instance the test builds with `.new`, is also listed with that class, as `Index.parse` or `Cart#total`. Among changed methods of one name, the related id is then the one on that class (or on a class whose name ends in it), unless none is, as for a method a superclass defines. Words in strings and comments are not mentions, except a method name passed as a plain string to `send`, `public_send`, `method`, or `respond_to?`, as in `send("total")`. A symbol that keys a Hash, as in `snap[:total]`, `snap.fetch(:total)`, or `{ total: 1 }`, is not a mention. A call to `message`, `full_message`, or `detailed_message` also mentions `to_s`, which an error class overrides to build its message. A helper in another file is not read.
- Files run one at a time unless you pass `--workers`. The base run and the head run of one file run at the same time, each in its own worktree, so a test that writes a fixed path outside the worktree or listens on a fixed port can collide with its other side, and with other files under `--workers`. The repository's existing suite is not run. The repository has to be able to add worktrees.
- An assertion backtrace usually stops in the test, so a library line is found from names the test mentions.
- An RSpec example's mentions come from its own block, the `let`, `subject`, and hook blocks of the groups around it, those groups' arguments, and the same-file helpers they call. A group described as `"#total"` or `".build"` names that method, and `described_class.new` names `Owner.new`. `described_class.parse` is listed as `Owner.parse`. A `let(:result)` or `subject(:result)` name is the spec's own helper, so neither it nor a bare `result` call mentions a changed method `result`. When its block builds one class, as `let(:cart) { Cart.new }` does, `cart.total` is listed as `Cart#total`. An implicit `subject`, a shared example group, and a helper in `spec/support` are not read; an example from a shared group defined in another file reads the whole candidate file.
- A Rails-style `rails_helper` loads in each worktree, but base and head run at the same time with the same `config/database.yml`. A candidate that writes to a database shares it with its other side. Only the shape of a Rails project is tested here; no Rails gem is.
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
