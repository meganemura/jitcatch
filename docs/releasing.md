# Releasing

A release publishes the gem to RubyGems, then creates the `v<version>` tag and the GitHub Release.
`.github/workflows/release.yml` does all three.
Nobody pushes a `v*` tag or runs `gem push` by hand.

## Cut a release

1. Write one commit that sets `VERSION` in `lib/jitcatch/version.rb` to the new version and renames `## [Unreleased]` in `CHANGELOG.md` to `## [<version>]`.
2. Land the commit on `main` through `queue`, as any other change lands.
3. The push to `main` starts the Release workflow.
   The `check` job reads the version and stops with nothing to do when the tag `v<version>` exists.
   Otherwise it reads the `## [<version>]` section of `CHANGELOG.md`, and fails when that section is missing or empty, before anything is published.
   The `test` job then runs `.github/workflows/ci.yml` on the commit.
4. Approve the `release` environment when the `publish` job asks for it.
   The job builds the gem and pushes it to RubyGems with trusted publishing.
5. The `release` job creates the tag on the released commit and a GitHub Release whose notes are the `CHANGELOG.md` section.

The first version is the one `lib/jitcatch/version.rb` already holds, 0.1.0.
The commit that renames `## [Unreleased]` to `## [0.1.0]` does not change `version.rb`, so its push starts nothing.
Start that release by hand from `main`: in the Actions tab, open Release and choose Run workflow on `main`, or run `gh workflow run release.yml --ref main`.
A run on any other branch stops at `check`.

When a job fails, rerun the failed jobs.
A push of a version that RubyGems already has is skipped, and a GitHub Release that exists gets its notes updated.

## One-time setup

Do these in this order, before the first release.

### Make the repository public

On GitHub Free, Pro, and Team plans, an environment's required reviewers work only in a public repository.
The `release` environment needs them, so make the repository public first.

### The GitHub environment

1. In the repository's Settings, open Environments and create an environment named `release`.
2. Under Required reviewers, add the owner.
3. Under Deployment branches and tags, choose Selected branches and tags and add the branch `main`.
   A push and a manual run both run the job from `main`, so a rule for `v*` tags alone blocks every release.

### The trusted publisher on RubyGems

The gem does not exist on RubyGems before the first release, so register a pending trusted publisher.
After the first successful push, RubyGems turns it into the gem's trusted publisher and adds the account as the gem's owner.

1. Sign in to RubyGems and open https://rubygems.org/profile/oidc/pending_trusted_publishers.
2. Choose Create and enter these values:

   | Field | Value |
   | --- | --- |
   | RubyGem name | `jitcatch` |
   | Trusted publisher type | GitHub Actions |
   | Repository owner | `meganemura` |
   | Repository name | `jitcatch` |
   | Workflow filename | `release.yml` |
   | Environment | `release` |

   Leave the workflow repository fields empty: the workflow lives in this repository.
3. Choose Create Pending trusted publisher.

A rename of the workflow file, of the environment, or of the repository breaks publishing until the publisher on RubyGems is changed to match.
