# Developing jitcatch

This file is for agents changing this repository. The usage loop for an agent applying jitcatch to some other project is [`skills/jitcatch/SKILL.md`](skills/jitcatch/SKILL.md).

## Tests

```sh
ruby -Ilib test/run.rb
```

Ruby 3.3 or newer. No gems. `minitest` and `prism` ship with Ruby.

Run it on Ruby 3.3 as well as on the newest Ruby before you push. Ruby 3.3 ships Prism 0.19, and the Prism API changed in 1.0: Prism 0.19 has no `ConstantPathNode#name`, for example. Outside a bundle, `test/test_helper.rb` loads the oldest installed `prism` and `minitest`, which are the ones that ship with Ruby, so the run matches a bare Ruby even when newer gems are installed. It also sets `MT_NO_PLUGINS`. A Ruby 3.3 with a newer prism must print `prism 0.19.0` here:

```sh
ruby -Ilib -e 'require "./test/test_helper"; puts "prism #{Prism::VERSION}"; $stdout.flush; exit!(0)'
```

The property tests in `test/property/` use hegeltest, which needs Ruby 3.4 or newer:

```sh
bundle install
bundle exec ruby -Ilib test/property/run.rb
```

They cover the assessor's counts and ids, the call edges a receiver names, the diff and Minitest parsers, the blob reader, qualified names, the names a test refers to, and the text helpers. Keep `test/run.rb` free of gems.

CI (`.github/workflows/ci.yml`) runs `test/run.rb` on Ruby 3.3 with no bundle, and both suites on Ruby 4.0.

`test/jitcatch/test_rspec_runner.rb` runs the real `rspec-core` on a Rails-shaped fixture (`.rspec`, `spec/spec_helper.rb`, `spec/rails_helper.rb`, no Rails gem). `rspec-core` and `rspec-expectations` are development gems in the `Gemfile`. `test/run.rb` loads no bundle, so there those tests skip on a Ruby that does not have `rspec-core` installed, which includes the Ruby 3.3 CI job. Run them with `bundle exec ruby -Ilib test/jitcatch/test_rspec_runner.rb`. CI does that on Ruby 4.0 with `JITCATCH_RSPEC=required`, which turns the skip into a failure. A rule that must hold for Minitest and RSpec alike gets a test in both runner files on one shared history: `inherited_history` in `test/test_helper.rb` is the unchanged subclass that still calls a removed method. A rerun line is checked by running it: split it with `Shellwords` and run it from the repository root, as printed.

To run jitcatch on its own commits with RSpec candidates, the bundle of both sides needs `rspec-core`, which the `Gemfile` lists. For a base from before the `Gemfile` listed it, in a scratch clone, commit those two `gem` lines (and `bundle lock --local`) on top of the base, cherry-pick the commits under review onto it, and pass that commit and the new tip as `BASE` and `HEAD`. The diff is then the same as the real one. Point a separate branch at that commit before you cherry-pick: a `BASE` branch that moved with the cherry-picks is the same commit as `HEAD`. `test/jitcatch/test_rspec_parser.rb` reads recorded RSpec json reports and needs no gem.

The engine tests build temporary git repositories and cover context, execution, flakes, timeouts, and signature-change discards. `test/jitcatch/test_shop_demo.rb` runs `script/setup_shop` in a temp directory and compares `context` and `run` to `examples/runs/*/context.txt` and `run.txt`, byte for byte.

`ruby script/setup_shop` writes a gitignored history at `examples/shop`. The sources are `examples/fixtures/shop/`. `examples/runs/` is the recorded demo, not a place to check in new candidate tests. If a change to rendering or the fixture moves those bytes, regenerate from the fixture and review the diff. Do not hand-edit the records to hide a mismatch. To regenerate a record, write the history to a scratch directory and run the CLI from this checkout:

```sh
ruby script/setup_shop /tmp/shop
mkdir -p /tmp/shop/candidates && cp -r examples/runs/regression/tests /tmp/shop/candidates/regression
ruby -Ilib bin/jitcatch run --repo /tmp/shop base regression /tmp/shop/candidates/regression > examples/runs/regression/run.txt
```

Use `intended` in place of `regression` for the other record, and `context --repo /tmp/shop base <ref>` for `context.txt`.

## Mutation testing

mutineer is not in the Gemfile. Run it from a Gemfile outside the repository (`gem "mutineer"` and `gem "minitest"`), with `BUNDLE_GEMFILE` pointing there, and name the test files that cover each source:

```sh
BUNDLE_GEMFILE=/path/to/Gemfile bundle exec mutineer run --since origin/queue \
  lib/jitcatch/assessor.rb --test test/jitcatch/test_assessor.rb --test test/jitcatch/test_render.rb
```

`--only 'JitCatch::Assessor#related_method'` scores one method, which also works on an archive of the base revision for a before score. `test/jitcatch/test_runner.rb` builds git repositories and takes about a minute per run, so scope `runner.rb`, `changes.rb`, and `git_repo.rb` with `--since` or `--only`. With that file among the `--test` files, pass `--timeout 150` too: a mutant over mutineer's default 10 seconds is a timeout, which the score leaves out, so a run that timed out 28 of 106 mutants still printed 100%. Read the `timeout` count next to the score. mutineer writes `.mutineer/` at the root, which git ignores. To score a source with the property tests too (`--test test/property/test_assessor_property.rb`), add `gem "hegeltest"` to that outside Gemfile. A change to the strings in `framework.rb` (the launch and rerun commands) has no Tier 1 mutant, and mutineer says `nothing to test in the changes since REF`. Score it with `--operators string_literal,array_literal,literal_mutation,return_nil`.

## Invariants

- The CLI does not call a model. Generation and the intended-versus-regression judgment stay outside the tool.
- The same repository and the same tests produce the same bytes. Fixed order, no timestamps, Minitest `--seed 1`, a worktree root written as `{worktree}` in messages and dropped from frames. Every command prints that document as JSON with `--json`.
- Exit status 0 is success, 1 is a usage error, 2 is a git error, and 3 means `run` stopped with no rows: a side failed its setup check, or no candidate file loaded on either side. Finding candidates still exits 0. The tool does not decide that something is a regression.
