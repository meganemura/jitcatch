# Developing jitcatch

This file is for agents changing this repository. The usage loop for an agent applying jitcatch to some other project is [`skills/jitcatch/SKILL.md`](skills/jitcatch/SKILL.md).

## Tests

```sh
ruby -Ilib test/run.rb
```

Ruby 3.3 or newer. No gems. `minitest` and `prism` ship with Ruby.

The property tests in `test/property/` use hegeltest, which needs Ruby 3.4 or newer:

```sh
bundle install
bundle exec ruby -Ilib test/property/run.rb
```

They cover the assessor's counts and ids, the diff and Minitest parsers, qualified names, and the text helpers. Keep `test/run.rb` free of gems.

CI (`.github/workflows/ci.yml`) runs `test/run.rb` on Ruby 3.3 with no bundle, and both suites on Ruby 4.0.

The engine tests build temporary git repositories and cover context, execution, flakes, timeouts, and signature-change discards. `test/jitcatch/test_shop_demo.rb` runs `script/setup_shop` in a temp directory and compares `context` and `run` to `examples/runs/*/context.txt` and `run.txt`, byte for byte.

`ruby script/setup_shop` writes a gitignored history at `examples/shop`. The sources are `examples/fixtures/shop/`. `examples/runs/` is the recorded demo, not a place to check in new candidate tests. If a change to rendering or the fixture moves those bytes, regenerate from the fixture and review the diff. Do not hand-edit the records to hide a mismatch.

## Invariants

- The CLI does not call a model. Generation and the intended-versus-regression judgment stay outside the tool.
- The same repository and the same tests produce the same bytes. Fixed order, no timestamps, Minitest `--seed 1`, absolute worktree paths stripped. Every command prints that document as JSON with `--json`.
- Exit status 0 is success, 1 is a usage error, and 2 is a git error. Finding candidates still exits 0. The tool does not decide that something is a regression.
