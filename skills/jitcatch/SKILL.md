---
name: jitcatch
description: Use when reviewing or landing a code change and you want throwaway tests that catch regressions it introduces. Drives the jitcatch CLI (context, run, assess) for a Ruby diff. Write Minitest files that pass on the base revision and fail on head, drop flakes, then judge each reported failure as a likely regression or an intended change. The tool never calls a model.
---

# jitcatch

`jitcatch` never calls a model. You write the tests. You decide whether a failure is a regression. The CLI prepares a brief, runs each test on the parent and on the change, and applies deterministic rules.

Do not commit the candidate tests unless the human asks to promote one.

## Prerequisites

Ruby 3.3 or newer, and git. No gems. `minitest` and `prism` ship with Ruby. The subject must be a git repository that can add worktrees. The tool reads commits only. Uncommitted files are not in the diff.

The executable is `bin/jitcatch` in the jitcatch repository. Run `jitcatch` when that `bin` directory is on `PATH`. Otherwise run `ruby /path/to/jitcatch/bin/jitcatch`. There is no gem. `jitcatch --help` prints the commands.

Exit status 0 is success, including when catching tests were found. Exit status 1 is a usage error. Exit status 2 is a git error.

## Choose base and head

`BASE` is the parent whose behavior should survive: the branch you would land onto, or `git merge-base` of that branch and the change. `HEAD` is the revision under review (a branch, `HEAD`, or a SHA). Both must resolve as `git rev-parse --verify REF^{commit}`. One exception: to review the first commit of a repository, pass `ROOT^` (or `ROOT~1`) as `BASE`. The parent of a root commit is read as the empty tree, so every file is added. On `run`, the base side is an empty directory, so every test is `fail_on_base`.

When `BASE` is not an ancestor of `HEAD` (for example, a main branch that moved on after the change branched off), the diff also undoes the commits only `BASE` has, and their methods show up as changed. `context` and `run` print `warning: base is not an ancestor of head` under `head`, with the count and the merge base. Pass that merge base as `BASE` and run again.

Pass `--repo DIR` when that repository is not the working directory.

Commit messages from `BASE` to `HEAD` are the intent the CLI can see (`git log BASE..HEAD`, oldest first, commits separated by `---`). The CLI leaves out the trailer block that git parses at the end of each message (`Co-Authored-By:`, `Signed-off-by:`, and the like). Git counts a last paragraph made only of `Word: text` lines as trailers too, so a closing line such as `Note: callers must refresh.` is also left out. When the intent looks cut short, read `git log BASE..HEAD`. Also read the pull request or the task when you have it. The tool does not.

## Context

```sh
jitcatch context --repo DIR BASE HEAD
jitcatch context --json --repo DIR BASE HEAD
jitcatch context --repo DIR --coverage FILE BASE HEAD
```

Omit `--repo` when the working directory is the repository.

Read `intent:` first. Then the changed files, `dependencies:` (each gem whose `Gemfile.lock` version changed, as `gem old -> new`, shown only when one did), constants (`k01`, …), and methods (`m01`, …). Each method has a change kind, signature, visibility, call sites, `reachable_from`, existing tests, and the old and new source. A method marked `affected` did not change its body. It reads a constant that did (`via=k01`). A class or module that only one side defines anywhere is listed as an `added` or `removed` constant, with its header line as the source. A file that reopens an existing class adds nothing. Methods defined in a block given to a constant (`Point = Struct.new(:x) do`, `Class.new do`, `Data.define do`) are listed under that constant (`Point#norm`), and the constant's source is the text before `do`.

`visibility=` follows `private`, `protected`, and `public` (bare, with names, or before a `def`), the same inside `class << self`, and `private_class_method` / `public_class_method` (with names or before `def self.x`). A `private` method is not an entry point. Test it through a public caller in `reachable_from`. A method after `module_function`, or named by it, is listed as the public module method `Mod.name`. A method of a class or module that `private_constant` names in the same file, or of anything nested in it, is listed as `private`, because a test cannot name its receiver. Visibility set by `send`, or by `private :name` written above its `def`, is not seen.

Methods in test files (under `test/` or `spec/`, or named `test_*.rb` or `*_test.rb`) are not listed, and are not entry points. The changed test files still appear under `files:`.

`tests: (none)` means no test file names that method. Then `entry_point_tests:` lists, when it finds any, the test files that call a public `reachable_from` entry point: the file names the entry point's class (`Cart.new`, not only `Cart::LIMIT`) and calls a method of that name (`.total`). Each file shows the entry points it matched. Read those tests before you write yours. They show how the repository builds the object and which inputs already reach the changed method. Like `tests:`, this line is a grep. It misses tests that drive the code through a subprocess or a factory, and it can list a file that calls a same-named method on another object. A `tests:` grep hit on a common name such as `initialize` or `call` can be any file that defines or calls that name.

The brief ends with one `entrypoints <Const>:` section for each class or module that holds a changed method. Each line is a public method of that class on head (on base when head has none) and its role: the change kind (`modified`, `added`, `affected`, `removed`) first, then `unchanged`, at most 12 lines. Pick the methods your tests call from this list. `run` counts these names as mentions too, so calling one gives a row its `touches:unchanged_caller` tag when it reaches a changed method.

`--coverage FILE` replaces the grep of existing tests. The file is JSON: `"format": "jitcatch-coverage-v1"` and a `tests` array of `{ "id", "file", "lines" }`, where `lines` maps repo paths to line numbers. Without it, the brief says `existing_tests grep`.

`--json` prints the same brief (`"command": "context"`).

## Write candidate tests

Write 3 to 6 Minitest files in a scratch directory you can delete.

A catching test states a behavior the old code already satisfies. Aim it at a changed or affected method, and at unchanged callers that reach that method (`reachable_from`). Prefer a boundary, a rounding case, or an error path the diff could disturb. One claim per test method. A test that only describes the new feature fails on base and is not evidence. Assert on one field, not on a whole returned Hash: a whole-Hash test (such as a branchout characterization test) fails on any added key, and its row prints one long line per side, so you have to find the difference by eye.

The `mentions` and the `touches:` tags read the test method's body and the bodies of the methods in the same file that it calls, directly or through other such methods. A helper in another file (`require "test/support/..."`) is not read, so call the changed method or its public caller from the candidate file. Prefer a public entry point over `send(:private_helper)`: a private helper can move between base and head, and the test then fails on base.

Each file:

- `require "minitest/autorun"`, then require the library the way the repo loads it (`require "shop"` when `lib/` is on the load path). The worktree root is on the load path too, so a test can reuse the repository's own helpers by path from the root (`require "test/support/repo"`). When you start from a copy of a repository test, rewrite `require_relative "../test_helper"` to `require "test/test_helper"`: the copy runs from `.jitcatch/`, where the relative path points at the worktree root and fails with `LoadError` on both sides.
- Name it `*_test.rb` or `test_*.rb`. When any file matches, other `*.rb` files are not executed. At most 40 files run.
- The runner copies the directory into each worktree at `.jitcatch/` and runs one process per file: `ruby -Ilib -I. .jitcatch/<file> -v --seed 1`.
- When the worktree has a `Gemfile`, the process also gets `-rbundler/setup` and `BUNDLE_GEMFILE` set to that worktree's `Gemfile`. Base and head then each load the gem versions their own `Gemfile.lock` names, so a test can catch a dependency bump. Only gems in the bundle load. When the `Gemfile` does not list `minitest`, no candidate can load it, and the report says `bundle base failed: minitest is not in the bundle`. Do not add `require "bundler/setup"` to the file yourself.
- Do not depend on the original path, on order, or on the clock. The base run and the head run of a file run at the same time, each in its own worktree, so do not write a fixed path outside the worktree (use `Dir.mktmpdir`) or listen on a fixed port. The child keeps only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `TEMP`, `TMP`, `LD_LIBRARY_PATH`, `GEM_HOME`, and `GEM_PATH`, and sets `LANG` and `LC_ALL` to `C.UTF-8` and `TERM` to `dumb`. Other variables, such as `RUBYOPT` from `bundle exec` or `CI`, do not reach it. When the library reads a variable of its own (for example `QUINT`, the command it runs), pass it with `--env QUINT`. Without it, the library falls back to its default, which can time out on both sides.
- A failure message shows the root of the worktree as `{worktree}/` (`{worktree}/lib/cart.rb`) and Ruby's prefix as `{ruby}/`, so an absolute path is still visibly a path. The worktrees sit under `Dir.tmpdir`, so a claim such as `refute_includes File.expand_path(__FILE__), Dir.tmpdir` fails on both sides. A failure message may name a path under the temp directory. The rerun check masks the name directly under `Dir.tmpdir`, so a new `Dir.mktmpdir` name on each run is not a disagreement. Another source of change in the message, such as a pid, a time, or an object id, still makes the test `flaky`.
- A file that builds a repository, starts processes, or runs a slow fixture needs more than the default 10 seconds. Raise `--timeout`. A timeout on head is discarded, and a timeout on base turns the whole file into one `fail_on_base` row (`<file>#timeout`). The text report prints `hint: head timed out after 10s; raise --timeout if the file needs longer` under that row.

## Run

```sh
jitcatch run --repo DIR BASE HEAD TESTS_DIR
jitcatch run --json --repo DIR --reruns 2 --timeout 10 --workers 2 BASE HEAD TESTS_DIR
```

`--reruns` defaults to 2: that many extra runs on head for a pass-on-base / fail-on-head result. `0` skips the flake check. `--timeout` defaults to 10 seconds per process (minimum 1). `run` takes no `--coverage`: its report lists no existing tests. `--workers N` runs N files at the same time, each in its own pair of worktrees; the default is 1. Pass `--workers 2` when the candidate files do not write the same fixed path or listen on the same port. Each worker runs two Ruby processes at once (base and head), so workers pay only when CPUs are idle: check `uptime` first, and leave the default when the load average is at or above the CPU count. On 4 CPUs, 40 files went from 9.7 to 6.2 seconds with 2 workers, and 4 workers were no faster than 2. On 5 small files, 2 workers saved 0.03 to 0.24 s of 1.4 s at load average 3, about 0.15 s of 2.0 s at load average 6, and nothing at load average 15, and 5 workers were no faster than 1. A worker's own setup (two worktrees) costs about 0.1 s; the time goes to the test processes. N above the file count adds no worker. The report is the same for every N. `--env NAME` passes one variable from your environment, and you can repeat it. The report lists the names on an `env` line. The text report already includes the assess section. Save the `--json` document if you will call `assess` later.

When either worktree has a `Gemfile`, the report prints `bundle base ok` or `bundle head failed: <message>` before `tests:`. A `failed` side cannot load its bundle, usually because a locked gem is not installed, or its bundle has no `minitest`. Every file on that side then fails to load. Install the gems (`bundle install` at that revision), or run from a copy of the repository whose `Gemfile` lists `minitest`, and run again before you judge any row.

Judge only rows whose disposition is `reported`.

| Bucket | Meaning |
| --- | --- |
| `no_signal` | Passed on both sides. Not evidence. |
| `fail_on_base` | The parent did not satisfy the test. Often a new feature. Not a candidate. |
| `flaky` | Passed on base, failed on head, then a rerun disagreed. Dropped. The text prints each rerun under the row (`rerun 1: pass`), and the `--json` row keeps them in `reruns`. |
| `discarded` | Stable pass-on-base / fail-on-head, removed by a rule. Still listed under `assess:`. |
| `reported` | You must judge this one. |

`generated` is the number of test methods. `candidates` counts stable pass-on-base / fail-on-head tests before the discard rules. `reported` is what remains.

Tags are hints, not a verdict. They are sorted:

- `touches:changed_method` — the test names a method the diff changed. `Owner.new` names `Owner#initialize`. Almost every test builds its object, so a changed constructor becomes the related id only when the test names no other changed method and reaches none through `reachable_from`.
- `touches:changed_dependency` — the error came from inside a gem that `dependencies:` lists: the first frame outside the candidate file is in that gem. An error whose first such frame is in any gem gets no `touches:changed_method`.
- `touches:changed_constant` — the test names a constant the diff changed, added, or removed. The row's `mentions` lists the bare names of changed methods, their classes' public methods, and changed constants that the test method or its same-file helpers name.
- `touches:unchanged_caller` — the test goes through an entry point the diff did not edit, and that entry point reaches a changed method.
- `discard:signature_change` — `NameError`, `NoMethodError`, or an arity `ArgumentError` on a symbol the diff removed or rewrote, including a removed nested class such as `Model::Unsupported`. An arity `ArgumentError` is `wrong number of arguments`, `missing keyword`, or `unknown keyword`, raised in a method whose signature changed. It counts too when `assert_raises(X)` caught it and failed with `[X] exception expected, not ArgumentError`. An `ArgumentError` raised on purpose is kept.
- `discard:load_error` — `LoadError` on head. `discard:timeout` — the head run timed out. Timeouts are not rerun.
- The related id (`m05`, or `-` when none) is the downstream modified method when several changed methods sit on the path. When the failure's backtrace runs through changed methods, it is the innermost of them. Read that method's old and new source before you judge.
- `related:guess` — the evidence that picked the related id points at several changed methods, most often because the test names only an unchanged caller (`build`, `between`) that reaches all of them. The next line, `related guess: m02 of m01,m02,m03`, lists every one (`method_ids` in `--json`). Read each of them before you judge, not only the pick. A test that names the method itself (through `send` when it is private) gets a firm id.
- A mention is a method call, a constant, or a symbol in the test code. Words in strings and comments are not mentions, so an expected string such as `"jitcatch run\n"` does not point the related id at a method named `run`. A method name passed as a plain string to `send`, `__send__`, `public_send`, `method`, `public_method`, or `respond_to?` is one (`send("total")`). A symbol that keys a Hash is not: an argument of `[]`, `[]=`, `fetch`, `dig`, `key?`, `has_key?`, `values_at`, or `fetch_values`, or a key in a hash literal or keyword argument. So `snap[:discount_cents]` does not point the related id at a method `discount_cents`, and `send(:discount_cents)` does.

## Judge

For each reported row, compare the failure (the message lines, usually expected and actual, and the related id) with the intent and with the diff in the brief. When Minitest printed a diff, the two lines are its first removed line (`-`, expected) and first added line (`+`, actual). The whole message is `head.message` in the `--json` document.

- **likely-regression** — behavior changed, and the intent does not ask for that change.
- **intended** — the intent explicitly wants that behavior.
- **unclear** — the intent is not enough to tell. Say what is missing.

The same pass-on-base / fail-on-head shape can be either. The diff shows what moved. The intent says whether that move was wanted. Do not promote a tag into the label.

## Assess

```sh
jitcatch assess RUN.json
jitcatch assess --json RUN.json
```

`RUN.json` is the document from `jitcatch run --json`, not the text report. This reprints the counts and the candidate rows. It does not call a model, and it does not decide intended versus regression.

## Report to the human

- The resolved base and head, and the intent in one or two lines.
- `generated`, `candidates`, `flaky`, and `reported`. Include `discarded` when it is not zero, with the discard tag.
- How many reported rows you marked likely-regression, intended, and unclear.
- One line per reported test: candidate id, name, judgment, and why. Cite the method id and what the intent says.
- When `reported` is 0, say so. A regression the candidate tests never stated does not appear. Mention `fail_on_base` only so a new-feature test is not mistaken for a regression.

## Afterward

Delete the scratch directory. The tests are throwaway. Promote one only when the human asks to keep it. A likely-regression test can join the real suite after the bug is fixed. An intended-change test encodes the old behavior, so do not keep it as written.
