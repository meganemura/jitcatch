# frozen_string_literal: true
# rbs_inline: enabled

# What a rerun line loads with `rspec -r jitcatch/rspec`. RSpec cuts an
# object it prints to 200 characters, which can cut the class and message a
# raise_error got out of the failure.
require "rspec/core"
require "rspec/support/object_formatter"

RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil
