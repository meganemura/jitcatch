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

`visibility=` follows `private`, `protected`, and `public` (bare, with names, or before a `def`), the same inside `class << self`, and `private_class_method` / `public_class_method` (with names or before `def self.x`). A `private` method is not an entry point. Test it through a public caller in `reachable_from`. Visibility set by `send`, by `module_function`, or by `private :name` written above its `def` is not seen.

Methods in test files (under `test/` or `spec/`, or named `test_*.rb` or `*_test.rb`) are listed too, when the change edits tests. They are not targets for candidate tests. Skip them.

`tests: (none)` means no test file names that method. Then `entry_point_tests:` lists, when it finds any, the test files that call a public `reachable_from` entry point: the file names the entry point's class (`Cart.new`, not only `Cart::LIMIT`) and calls a method of that name (`.total`). Each file shows the entry points it matched. Read those tests before you write yours. They show how the repository builds the object and which inputs already reach the changed method. Like `tests:`, this line is a grep. It misses tests that drive the code through a subprocess or a factory, and it can list a file that calls a same-named method on another object. A `tests:` grep hit on a common name such as `initialize` or `call` can be any file that defines or calls that name.

`--coverage FILE` replaces the grep of existing tests. The file is JSON: `"format": "jitcatch-coverage-v1"` and a `tests` array of `{ "id", "file", "lines" }`, where `lines` maps repo paths to line numbers. Without it, the brief says `existing_tests grep`.

`--json` prints the same brief (`"command": "context"`).

## Write candidate tests

Write 3 to 6 Minitest files in a scratch directory you can delete.

A catching test states a behavior the old code already satisfies. Aim it at a changed or affected method, and at unchanged callers that reach that method (`reachable_from`). Prefer a boundary, a rounding case, or an error path the diff could disturb. One claim per test method. A test that only describes the new feature fails on base and is not evidence.

Each file:

- `require "minitest/autorun"`, then require the library the way the repo loads it (`require "shop"` when `lib/` is on the load path). The worktree root is on the load path too, so a test can reuse the repository's own helpers by path from the root (`require "test/support/repo"`).
- Name it `*_test.rb` or `test_*.rb`. When any file matches, other `*.rb` files are not executed. At most 40 files run.
- The runner copies the directory into each worktree at `.jitcatch/` and runs one process per file: `ruby -Ilib -I. .jitcatch/<file> -v --seed 1`.
- When the worktree has a `Gemfile`, the process also gets `-rbundler/setup` and `BUNDLE_GEMFILE` set to that worktree's `Gemfile`. Base and head then each load the gem versions their own `Gemfile.lock` names, so a test can catch a dependency bump. Only gems in the bundle load. If `require "minitest/autorun"` fails with `LoadError` on both sides, the `Gemfile` does not list `minitest`. Do not add `require "bundler/setup"` to the file yourself.
- Do not depend on the original path, on order, or on the clock. The child keeps only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `TEMP`, `TMP`, `LD_LIBRARY_PATH`, `GEM_HOME`, and `GEM_PATH`, and sets `LANG` and `LC_ALL` to `C.UTF-8` and `TERM` to `dumb`. Other variables, such as `RUBYOPT` from `bundle exec` or `CI`, do not reach it. When the library reads a variable of its own (for example `QUINT`, the command it runs), pass it with `--env QUINT`. Without it, the library falls back to its default, which can time out on both sides.
- A failure message may name a path under the temp directory. The rerun check masks the name directly under `Dir.tmpdir`, so a new `Dir.mktmpdir` name on each run is not a disagreement. Another source of change in the message, such as a pid, a time, or an object id, still makes the test `flaky`.
- A file that builds a repository, starts processes, or runs a slow fixture needs more than the default 10 seconds. Raise `--timeout`. A timeout on head is discarded, and a timeout on base turns the whole file into one `fail_on_base` row (`<file>#timeout`).

## Run

```sh
jitcatch run --repo DIR BASE HEAD TESTS_DIR
jitcatch run --json --repo DIR --reruns 2 --timeout 10 BASE HEAD TESTS_DIR
```

`--reruns` defaults to 2: that many extra runs on head for a pass-on-base / fail-on-head result. `0` skips the flake check. `--timeout` defaults to 10 seconds per process (minimum 1). `--coverage` is the same flag as on `context`. `--env NAME` passes one variable from your environment, and you can repeat it. The report lists the names on an `env` line. The text report already includes the assess section. Save the `--json` document if you will call `assess` later.

When either worktree has a `Gemfile`, the report prints `bundle base ok` or `bundle head failed: <message>` before `tests:`. A `failed` side cannot load its bundle, usually because a locked gem is not installed, and every file on that side fails to load. Install the gems (`bundle install` at that revision) and run again before you judge any row.

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

- `touches:changed_method` — the test names a method the diff changed.
- `touches:changed_dependency` — the error came from inside a gem that `dependencies:` lists: the first frame outside the candidate file is in that gem. An error whose first such frame is in any gem gets no `touches:changed_method`.
- `touches:changed_constant` — the test names a constant the diff changed, added, or removed. The row's `mentions` lists the bare names of changed methods and constants the test method names.
- `touches:unchanged_caller` — the test goes through an entry point the diff did not edit, and that entry point reaches a changed method.
- `discard:signature_change` — `NameError`, `NoMethodError`, or an arity `ArgumentError` on a symbol the diff removed or rewrote, including a removed nested class such as `Model::Unsupported`. An arity `ArgumentError` is `wrong number of arguments`, `missing keyword`, or `unknown keyword`, raised in a method whose signature changed. It counts too when `assert_raises(X)` caught it and failed with `[X] exception expected, not ArgumentError`. An `ArgumentError` raised on purpose is kept.
- `discard:load_error` — `LoadError` on head. `discard:timeout` — the head run timed out. Timeouts are not rerun.
- The related id (`m05`, or `-` when none) is the downstream modified method when several changed methods sit on the path. Read that method's old and new source before you judge.

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
