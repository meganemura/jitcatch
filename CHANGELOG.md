# Changelog

## [Unreleased]

First release. jitcatch keeps the Ruby tests that pass on the parent of a change and fail on the change, and names the changed method each one reaches. It never calls a model: an agent writes the candidate tests and judges each result.

- `jitcatch context BASE HEAD` prints a short brief of a change: each changed method with its old and new source, its call sites, the entry points that reach it, and the tests that mention it. It also lists changed constants, gems whose locked version changed, and the Rails callbacks, validations, and FactoryBot factories that run a changed method.
- `jitcatch run BASE HEAD TESTS_DIR` runs each candidate Minitest file or RSpec spec on both revisions, each in its own worktree with its own bundle. It reruns to drop flaky tests, removes non-signals such as load errors, timeouts, and signature changes, and reports what is left. Each reported row shows the old and the new result, the changed method it reaches, and a `rerun:` command for that one test.
- `jitcatch assess RUN.json` applies the rules again to a saved run.
- `--json` on every command prints the same result for a program to read.
- Rails apps: candidates can use the app's factories and test database. When base and head would share one test database on a database server, `run` runs one process at a time and says which line of `config/database.yml` to change.
- A symlinked `.rb` file is not indexed, so it no longer shows up under `parse_errors`. git stores a symlink as the path it points at; the target file is indexed on its own.
- A row shows the `got` line of a failed RSpec `be` or `equal`, and the `expected:` and `got:` arguments of an rspec-mocks failure on unexpected arguments, under `assess:` and under a `fail_on_base` row's `base:`.
- An Active Record `scope` is a changed class method (`Post.recent`) when its statement changes, a `delegate` line defines instance methods, and an `enum :status, {...}` value defines its predicate, bang, and two scopes. Each then gets call sites, tests, and an `entrypoints` line, and `run` counts the names as mentions.
- A candidate that fails the same way on every head rerun, with only its message moving (a random id in a printed record), is kept with the tag `message_varies` when base also passes on `--reruns` reruns, instead of turning `flaky`. A flaky row's rerun line says `(same outcome, message differs)` when only the message moved, lists the base reruns, and is cut at 300 characters.
- `dynamic_callers:` no longer lists a call that only sends the name of a controller action in `reachable_from`, such as `cipher.update` next to `ThingsController#update`: the router calls an action, and no code in the app sends its name.
- An agent skill in `skills/jitcatch/`.
- Ruby 3.3 or newer. No runtime dependency. On an older Ruby, `jitcatch` exits 1 and names the version it needs and the Ruby it ran on.
