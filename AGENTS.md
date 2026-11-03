# jittest agent loop

`jittest` never calls an LLM. You write the tests. You decide whether a failure is a regression. The CLI only prepares a brief, runs the tests on the parent and the change, and applies deterministic rules.

Do not commit the candidate tests into the target repository. They are throwaway.

## Test contract

- Minitest files. `require "minitest/autorun"` and require the library the way the repo loads it (`require "shop"` when `lib/` is on the load path).
- The runner copies the directory into each worktree at `.jittest/` and executes every `*_test.rb` / `test_*.rb` with `ruby -Ilib -I. file -v --seed 1`.
- One file, one process. Do not depend on the original path, on order, or on the clock.
- Write 3 to 6 files. Cover the changed methods and the unchanged behavior next to the change: boundaries, rounding, and error paths. A test that only describes the new feature fails on the parent and is discarded. A catching test is one the old code already satisfies.

## Loop

1. Read the change intent (PR body, or the commit messages `jittest context` prints).
2. Run `jittest context BASE HEAD` (add `--repo` when the git repo is not the working directory). Note the method ids (`m01`, …) and constant ids (`k01`, …).
3. Write the minitest files into a scratch directory.
4. Run `jittest run BASE HEAD scratch_dir/`. Default `--reruns` is 2 and `--timeout` is 10 seconds. Add `--json` if you want the same document as JSON.
5. Read the assess section. For each reported row, judge:
   - **likely-regression** — behavior changed and the intent does not ask for that change.
   - **intended** — the intent explicitly wants that behavior.
   - **unclear** — the intent is not enough to tell.
6. Write a short report: the counts, and one line per reported test with the judgment and why.
7. Delete the scratch directory. Do not add it to the target suite.

`jittest assess RUN.json` reprints the judgment aid from a saved run. It does not call a model either.

## How to read a row

| Bucket | Meaning |
| --- | --- |
| `no_signal` | Passed on both sides. Not evidence. |
| `fail_on_base` | The parent did not satisfy the test. Often a new feature. Discarded. |
| `flaky` | Passed the parent, failed the change, then did not fail the same way again. Dropped. |
| `discarded` | Stable pass/fail, removed by a rule: `signature_change`, `load_error`, or `timeout`. |
| `reported` | You must judge this one. |

`candidates` counts stable pass-on-base / fail-on-head tests before those rules. `reported` is what remains.

Tags are hints, not a verdict:

- `touches:changed_method` — the test method names a method the diff changed.
- `touches:unchanged_caller` — the test goes through an entry point the diff did not edit, and that entry point reaches a changed method.
- `discard:signature_change` — `NameError` / `NoMethodError` / arity `ArgumentError` on a symbol whose signature the diff removed or rewrote. An `ArgumentError` raised on purpose (`qty must be > 0`) is kept.
- The related id (`m05`, …) is the downstream modified method on the path when several changed methods match. Read that method in the context brief before you judge.

## Counts to put in the report

`generated`, `candidates`, `flaky`, `reported`. Also say how many of the reported rows you marked likely-regression, intended, and unclear.
