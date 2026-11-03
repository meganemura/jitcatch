# frozen_string_literal: true

require_relative "property_helper"
require "shellwords"

class TestRSpecProperty < Minitest::Test
  STATUSES = { "passed" => "pass", "pending" => "skip", "failed" => "fail" }.freeze

  def test_every_example_is_one_test_at_its_own_line
    Hegel.test do |tc|
      count = tc.draw(integers(min_value: 0, max_value: 8))
      lines = tc.draw(arrays(integers(min_value: 1, max_value: 400), min_size: count, max_size: count, unique: true))
      examples = lines.map do |line|
        status = tc.draw(sampled_from(STATUSES.keys))
        {
          "full_description" => tc.draw(sampled_from(["Cart sums", "Cart#total rounds", "Cart sums (line 9)"])),
          "status" => status,
          "line_number" => line,
          "exception" => status == "failed" ? { "class" => "RSpec::Expectations::ExpectationNotMetError", "message" => "expected: 1", "backtrace" => [] } : nil
        }.compact
      end

      parsed = JitCatch::RSpecParser.parse(JSON.generate("examples" => examples, "summary" => {}), "", "")

      assert_equal examples.size, parsed["tests"].size
      assert_equal lines.sort, parsed["lines"].values.sort
      by_line = examples.to_h { |example| [example["line_number"], STATUSES.fetch(example["status"])] }
      parsed["lines"].each { |name, line| assert_equal by_line.fetch(line), parsed["tests"].fetch(name)["status"] }
    end
  end

  def test_a_rerun_command_reads_back_as_the_words_it_was_built_from
    Hegel.test do |tc|
      file = tc.draw(from_regex("[a-z _'\"$#]{1,8}_spec\\.rb"))
      line = tc.draw(integers(min_value: 1, max_value: 999))
      name = tc.draw(from_regex("[A-Za-z#:' \"$`!]{1,12}"))

      assert_equal ["rspec", "{tests}/#{file}:#{line}"], Shellwords.split(JitCatch::Framework::RSpec.rerun(file, nil, line))
      assert_equal ["ruby", "-Ilib", "-I.", "{tests}/#{file}", "-n", name], Shellwords.split(JitCatch::Framework::Minitest.rerun(file, name, nil))
    end
  end
end
