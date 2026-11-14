# frozen_string_literal: true

source "https://rubygems.org"

# test/run.rb needs no gems. The property tests in test/property use
# hegeltest, and the RSpec engine tests in test/jitcatch/test_rspec_runner.rb
# run the real rspec-core; without it they skip.
gem "hegeltest", "0.5.1"
gem "minitest", "6.0.6"
gem "rspec-core", "3.13.6"
gem "rspec-expectations", "3.13.5"

# rbs-inline writes sig/generated from the comments in lib/, and Steep checks
# lib/ against it. They run in the bundle on Ruby 3.4 and newer; the Ruby 3.3
# job in CI installs no bundle.
group :types do
  gem "rbs-inline", "0.14.0", require: false
  gem "steep", "2.1.0", require: false
end
