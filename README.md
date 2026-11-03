# jitcatch

A deterministic prototype of Just-in-Time catching tests for Ruby. For each change, run tests aimed at the diff on both the parent (base) and the change (head). Keep only the tests that pass on base and fail on head. Drop flakes and obvious non-signals with rules. An agent then decides whether each remaining failure is intended or a regression.

**This tool never calls an LLM.** A coding agent (Claude Code, Cursor, or a person) writes the tests and judges intent. The CLI only prepares a short brief, runs the tests, and classifies them.

Ruby 3.3 or newer (4.0 is fine). No extra gems. `minitest` and `prism` ship with Ruby. Checked on Ruby 3.3.13.

## Design

The subject is two commits in a git repository. The same inputs produce the same bytes. Order is fixed, and the compact output has no timestamps. Minitest runs with `--seed 1`. Absolute worktree paths are stripped from results. Every command prints the same document as JSON with `--json`.

```
jitcatch context [--json] [--repo DIR] [--coverage FILE] BASE HEAD
jitcatch run     [--json] [--repo DIR] [--coverage FILE] [--reruns N] [--timeout SEC] BASE HEAD TESTS_DIR
jitcatch assess  [--json] RUN.json
```

Exit status 0 is success, 1 is a usage error, and 2 is a git failure. Finding candidates still exits 0. The tool does not decide whether something is a regression.

`context` prints a short brief for an agent:

- Changed files.
- Diff hunks mapped to methods with Prism. Each method gets a stable id (`m01`, …).
- Old and new source of each changed method. When only a constant changes, methods that read it are listed as `affected` (`k01`).
- Callers of changed methods inside the library, and the public entry points that reach them.
- Existing tests that reference them. The default is a grep of test files. `--coverage` uses that file instead.

`run` creates git worktrees for base and head in a temporary directory, copies each candidate file to `.jitcatch/`, and runs it with `ruby -Ilib -I.`. The default timeout is 10 seconds. Classification:

| Result | Meaning |
| --- | --- |
| pass / pass | `no_signal`. Not evidence. |
| pass / fail | Catching candidate. The old code satisfied the claim, and the new code broke it. |
| Fail on base | `fail_on_base`. The test is broken, or it only describes a new feature. Discarded. |
| Rerun candidates on head | Default 2 extra runs. If any rerun disagrees, the test is `flaky` and dropped. |
| `LoadError`, timeout, or `NameError` / `NoMethodError` / arity `ArgumentError` on a signature the diff changed | `discarded` |

`assess` applies rules only. For each remaining candidate it prints the test name, the base and head results, the first line of the failure, the related method id, and tags. `touches:changed_method` means the test names a method the diff changed. `touches:unchanged_caller` means an entry point the diff did not edit still reaches a changed method. When several changed methods sit on the path, the related id is the downstream method that already existed, rather than one the diff only added.

The tool does not separate intended changes from regressions. That is the agent's job. The steps are in [skills/jitcatch/SKILL.md](skills/jitcatch/SKILL.md).

## Run

```sh
ruby script/setup_shop          # build a reproducible git history at examples/shop
bin/jitcatch context --repo examples/shop base regression
bin/jitcatch run --repo examples/shop base regression examples/runs/regression/tests
ruby -Ilib test/run.rb          # engine tests
```

`examples/shop` is generated and is not part of this repository. The sources live in `examples/fixtures/shop/`.

Do not commit candidate tests into the target repository. `examples/runs/` in this repository is the record of acting as the agent on the demo.

## Agent loop

1. Read `jitcatch context BASE HEAD`. The intent is the commit messages from `BASE` to `HEAD`.
2. Write 3 to 6 Minitest files for the changed methods and for unchanged behavior next to the change: boundaries, rounding, and error paths.
3. Run `jitcatch run BASE HEAD tests_dir/`.
4. Judge each reported row against the intent: likely-regression, intended, or unclear.
5. Write a short report with the counts and the judgments. Discard the tests.

A test that only asserts the new feature fails on base and is not a candidate. A catching test states something the old code already satisfied.

## Using with coding agents

The procedure an agent follows while reviewing or landing a change is [skills/jitcatch/SKILL.md](skills/jitcatch/SKILL.md). [AGENTS.md](AGENTS.md) is for changing this repository.

Install the skill by copying or symlinking the `skills/jitcatch` directory into the agent's skills directory, for example `.agents/skills/`, `.claude/skills/`, or `.cursor/skills/`. The agent still needs this repository's `bin/jitcatch` on `PATH` (Ruby 3.3 or newer). Copying the skill does not install the executable.

## Mapping to Meta's pipeline

Meta's Just-in-Time Catching Test Generation (arXiv 2601.22832; engineering.fb.com, 2026-02-11 and 2026-10-29) generates tests for a diff, runs them on the parent and on head, and keeps tests that pass on the parent and fail on head. A rerun drops flakes. Rules and an LLM judge separate intended behavior changes from likely regressions. Only likely regressions are reported. The tests are throwaway.

The Vitest experiment (github.com/hbmartin/catching-jit-tests-vitest) puts the same pass/fail filter outside the model.

| Meta | jitcatch |
| --- | --- |
| Select the change | `git diff BASE HEAD` and Prism |
| Generate tests (a model) | An agent reads `context` and writes Minitest |
| Run on base and head | Worktrees, one `ruby` process per file |
| Keep pass/fail only | `candidate` |
| Drop flakes | `--reruns` (default 2) |
| Rules plus an LLM judge | Rules are `assess`. The agent judges intent. |
| Report regressions | The agent writes the final report |
| Tests are throwaway | They are not added to the target repository |

## Demo

`examples/fixtures/shop` is a cart priced in integer cents (73 lines of library code at base). A 10% volume discount applies once the subtotal reaches 10000 cents. Tax is 8%, rounded half up. The existing tests cover 4000 cents, 15000 cents, and rounding at 12 cents. They never check exactly 10000.

`ruby script/setup_shop` builds that history with a fixed author and dates, so the commit SHAs match on any machine that runs the script.

| Branch | SHA | Contents |
| --- | --- | --- |
| base | `cf7f35144524b7a0606df29197ac609b2f17773f` | Initial implementation |
| regression | `f2f5f6c3778bca3f65d06728583ca9e089523dfc` | Adds SAVE5 and changes the threshold comparison from `<` to `<=`. The message talks only about the coupon. |
| intended | `f8505c45e71a6f219d1e0dfa26728c296b4d2d42` | Lowers the threshold to 5000. The message says that change is intentional. |

The existing `test/test_cart.rb` passes on all three. The regression sits in a gap in the original suite.

### Case 1: a feature, and a regression on an existing boundary

The intent is "SAVE5 takes 500 cents off before tax." m05 in `context` looks like this (the full brief is `examples/runs/regression/context.txt`, 93 lines):

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

The tests written from that brief are 5 files and 13 methods: the boundary (9999 / 10000 / 10001), the total at 10000, rounding, input checks, and SAVE5. The run (`examples/runs/regression/run.txt`):

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

Both are **likely-regression**. 10800 is the taxed total with no discount, and 9720 is the total after the discount. Both come from `<=` dropping the discount at exactly 10000 cents. The intent does not ask for that. The three SAVE5 tests fail on base (two `NoMethodError`s because `apply_coupon` is missing, one `NameError` because `Shop::UnknownCoupon` is missing) and are not candidates. Rounding and 9999 / 10001 are pass/pass. Flaky is 0, and the rules discarded 0. Nothing is unclear.

That is 2 reported tests and 1 regression. The write-up is `examples/runs/regression/report.md`.

### Case 2: an intended behavior change

Only a constant changes. The method body is the same, so it is listed as `affected` (the full brief is `examples/runs/intended/context.txt`, 35 lines):

```
constants:
  [k01] modified Shop::Cart::VOLUME_THRESHOLD_CENTS lib/shop/cart.rb:7
    old: VOLUME_THRESHOLD_CENTS = 10_000
    new: VOLUME_THRESHOLD_CENTS = 5_000
    readers: m01
methods:
  [m01] affected Shop::Cart#volume_discount_cents lib/shop/cart.rb:30-34 signature=same visibility=public via=k01
```

Nine methods: tests that still state the old boundary, a test that states the new rule directly, and checks for rounding and quantity. The run (`examples/runs/intended/run.txt`):

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

Both are **intended**. The intent says orders of 5000 cents or more get 10% off. A 7500-cent total moving from 8100 to 7290 is inside that change. The test that asserts the new rule directly fails on base and is not a candidate. Likely-regression is 0. Nothing is unclear. Flaky is 0.

The same pass/fail shape is a regression in case 1 and an intended change in case 2. The difference is the commit message, not the shape of the diff.

## Why the tool does not call an LLM

- **Determinism.** The same repository and the same tests produce the same bytes. The engine tests compare the demo record to a fresh run. Model version and temperature cannot change the result.
- **Cost.** Generation and judgment can use the model the agent is already paying for. The CLI does not need its own API call.
- **Any agent can drive it.** Claude Code, Cursor, or a person follow the same commands. The tool is not tied to one model.
- **Judging intent needs the pull request and the conversation.** The agent already has that context. Baking one judge into the CLI would freeze that choice and make the output untestable.

## Limitations

- Call sites are matched by name, not by type. Two methods with the same name can drop a caller or point the related id at the wrong method.
- `define_method`, `class_eval`, and `def` inside a conditional are not indexed. Definitions with a receiver other than `def self.foo` are coarse.
- Renames are seen as a deletion plus an addition (`--no-renames`).
- The tool does not collect coverage. It only reads the JSON passed to `--coverage`.
- The rules drop signature changes, `LoadError`, and timeouts. An `ArgumentError` raised on purpose, such as `qty must be > 0`, is kept. The rules do not separate intent from regression.
- If the candidate tests do not state the old behavior, the regression is not found. This bug is a gap in the existing suite. Without a boundary test, reported stays 0.
- Tests of a new feature fail on base and disappear. That is the design. They are not a substitute for catching a regression.
- The related id is a heuristic. The cause can sit one step further upstream.
- A mention is a word in the test method's source. Naming a method in a comment pulls the tag toward it.
- Timeouts are not rerun. Files run one at a time, with no parallelism.
- The target's existing suite is not executed. The repository must be a git repo that can make worktrees.
- An assertion failure's backtrace usually stops in the test, so tags for library lines fall back to method names mentioned in the test.

## Next steps

**Per-test simplecov coverage.** The accepted shape is `jitcatch-coverage-v1` (see `examples/coverage/jitcatch-coverage-v1.sample.json`).

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

`--coverage` lists tests whose covered lines overlap a changed method, instead of grepping. The next piece is an adapter from simplecov's per-test result, or from the lines `simplecov affected` reports, into this JSON. Collection stays outside the tool.

**Property tests from hegel-ruby (gem `hegeltest`) as the generated tests.** Write the discount threshold and the rounding rule as properties instead of single points. The same pass/fail filter runs them. The gem is not a dependency here.

**A GitHub Actions `@jitcatch` comment.** A pull-request comment triggers `context`, an agent writes tests and a report, and the report is posted back. This prototype does not include the account or the workflow.

**One-shot end-to-end.** Use the same base/head filter for a single request or browser smoke that hits the changed entry point. Those tests are throwaway too.

**An in-tool LLM variant.** A CLI with a model inside would generate tests and judge intended versus regression in the command. The output would no longer be byte-stable, and the tool would need secrets and a budget that the engine tests could not pin down. This prototype keeps the model outside the loop and the tool a pure function. A hybrid can keep that default and shell out only when asked.

## Development

Notes for agents changing this repository are in [AGENTS.md](AGENTS.md).

```sh
ruby -Ilib test/run.rb
```

The engine tests use temporary git repositories to cover context, execution, flakes, timeouts, and signature-change discards. The shop demo in `test/jitcatch/test_shop_demo.rb` rebuilds the fixture and compares `context.txt` and `run.txt` to the recorded files, byte for byte.

## License

No license has been chosen yet.

Japanese documentation: [README.ja.md](README.ja.md).
