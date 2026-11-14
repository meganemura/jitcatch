# frozen_string_literal: true

# sig/generated is written by `bundle exec rbs-inline --output=sig/generated lib`
# from the comments in lib/. Run `bundle exec steep check` after a change to lib/.
# sig-deps holds what lib/ calls that the bundled signatures do not declare;
# the gem ships sig/ only.
target :lib do
  signature "sig", "sig-deps"
  check "lib"
  # These two are loaded into a candidate's process, never into jitcatch.
  # rspec.rb only sets one rspec-support value, and rspec ships no RBS that
  # Steep could load. minitest_report.rb defines its methods in anonymous
  # modules it prepends to Minitest's own, which RBS cannot name.
  ignore "lib/jitcatch/rspec.rb", "lib/jitcatch/minitest_report.rb"

  library "json", "open3", "fileutils", "pathname", "tmpdir", "uri", "prism"
end
