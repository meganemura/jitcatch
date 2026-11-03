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

They cover the assessor's counts and ids, the call edges a receiver names, the diff and Minitest parsers, the blob reader, qualified names, the names a test refers to, and the text helpers. Keep `test/run.rb` free of gems.

CI (`.github/workflows/ci.yml`) runs `test/run.rb` on Ruby 3.3 with no bundle, and both suites on Ruby 4.0.

`test/jitcatch/test_rspec_runner.rb` runs the real `rspec-core` on a Rails-shaped fixture (`.rspec`, `spec/spec_helper.rb`, `spec/rails_helper.rb`, no Rails gem). `rspec-core` is not a dependency of jitcatch, so those tests skip on a Ruby that does not have it installed, which includes CI today. Run them locally on a Ruby with `rspec` installed. `test/jitcatch/test_rspec_parser.rb` reads recorded RSpec json reports and needs no gem.

The engine tests build temporary git repositories and cover context, execution, flakes, timeouts, and signature-change discards. `test/jitcatch/test_shop_demo.rb` runs `script/setup_shop` in a temp directory and compares `context` and `run` to `examples/runs/*/context.txt` and `run.txt`, byte for byte.

`ruby script/setup_shop` writes a gitignored history at `examples/shop`. The sources are `examples/fixtures/shop/`. `examples/runs/` is the recorded demo, not a place to check in new candidate tests. If a change to rendering or the fixture moves those bytes, regenerate from the fixture and review the diff. Do not hand-edit the records to hide a mismatch. To regenerate a record, write the history to a scratch directory and run the CLI from this checkout:

```sh
ruby script/setup_shop /tmp/shop
ruby -Ilib bin/jitcatch run --repo /tmp/shop base regression examples/runs/regression/tests > examples/runs/regression/run.txt
```

Use `intended` in place of `regression` for the other record, and `context --repo /tmp/shop base <ref>` for `context.txt`.

## Mutation testing

mutineer is not in the Gemfile. Run it from a Gemfile outside the repository (`gem "mutineer"` and `gem "minitest"`), with `BUNDLE_GEMFILE` pointing there, and name the test files that cover each source:

```sh
BUNDLE_GEMFILE=/path/to/Gemfile bundle exec mutineer run --since origin/queue \
  lib/jitcatch/assessor.rb --test test/jitcatch/test_assessor.rb --test test/jitcatch/test_render.rb
```

`--only 'JitCatch::Assessor#related_method'` scores one method, which also works on an archive of the base revision for a before score. `test/jitcatch/test_runner.rb` builds git repositories and takes about a minute per run, so scope `runner.rb`, `changes.rb`, and `git_repo.rb` with `--since` or `--only`. mutineer writes `.mutineer/` at the root, which git ignores.

## Invariants

- The CLI does not call a model. Generation and the intended-versus-regression judgment stay outside the tool.
- The same repository and the same tests produce the same bytes. Fixed order, no timestamps, Minitest `--seed 1`, a worktree root written as `{worktree}/` in messages and dropped from frames. Every command prints that document as JSON with `--json`.
- Exit status 0 is success, 1 is a usage error, and 2 is a git error. Finding candidates still exits 0. The tool does not decide that something is a regression.
