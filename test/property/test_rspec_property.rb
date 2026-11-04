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

  def test_a_cause_takes_the_lines_after_its_marker_and_none_of_its_frames_reach_the_error
    Hegel.test do |tc|
      frame = -> { [tc.draw(from_regex("lib/[a-z]{1,6}\\.rb", fullmatch: true)), tc.draw(integers(min_value: 1, max_value: 99))] }
      own = Array.new(tc.draw(integers(min_value: 0, max_value: 4))) { frame.call }
      theirs = Array.new(tc.draw(integers(min_value: 0, max_value: 4))) { frame.call }
      message = tc.draw(arrays(from_regex("[a-z][a-z :]{0,12}", fullmatch: true), min_size: 0, max_size: 3))
      error_class = tc.draw(from_regex("[A-Z][a-z]{0,6}(::[A-Z][a-z]{0,6})?", fullmatch: true))
      backtrace = own.map { |file, line| "./#{file}:#{line}:in 'g'" } + ["------------------", "--- Caused by: ---", "#{error_class}:"] +
        message.map { |text| "  #{text}" } + theirs.map { |file, line| "  ./#{file}:#{line}:in 'h'" }
      example = { "full_description" => "A g", "status" => "failed", "line_number" => 1, "exception" => { "class" => "W", "message" => "m", "backtrace" => backtrace } }

      result = JitCatch::RSpecParser.parse(JSON.generate("examples" => [example], "summary" => {}), "", "")["tests"].fetch("A g")

      assert_equal own, result["backtrace"].map { |item| [item["file"], item["line"]] }
      assert_equal({ "error_class" => error_class, "message" => message.map(&:strip).join("\n") }, result["cause"])
    end
  end

  def test_a_rerun_command_reads_back_as_the_words_it_was_built_from
    Hegel.test do |tc|
      file = tc.draw(from_regex("[a-z _'\"$#]{1,8}_spec\\.rb"))
      line = tc.draw(integers(min_value: 1, max_value: 999))
      name = tc.draw(from_regex("[A-Za-z#:' \"$`!]{1,12}"))

      assert_equal ["ruby", "-Ilib", "-I.", "-e", JitCatch::Framework::RSpec::LAUNCH, "{tests}/#{file}:#{line}"], Shellwords.split(JitCatch::Framework::RSpec.rerun(file, nil, line))
      assert_equal ["ruby", "-Ilib", "-I.", "{tests}/#{file}", "-n", name], Shellwords.split(JitCatch::Framework::Minitest.rerun(file, name, nil))
    end
  end

  def test_a_message_line_of_any_shape_stays_in_the_message
    Hegel.test do |tc|
      lines = tc.draw(arrays(from_regex(LINE_OF_ANY_SHAPE, fullmatch: true), max_size: 8))
      quoted = Array.new(tc.draw(integers(min_value: 0, max_value: 3))) { [tc.draw(from_regex("lib/[a-z]{1,6}\\.rb", fullmatch: true)), tc.draw(integers(min_value: 1, max_value: 99))] }
      header = quoted.empty? ? [] : ["got #<KeyError: k> with backtrace:"]
      message = ["expected: 1", *lines, *header, *quoted.map { |file, line| "  # ./#{file}:#{line}:in 'g'" }].join("\n")
      example = { "full_description" => "A g", "status" => "failed", "line_number" => 1, "exception" => { "class" => "RSpec::Expectations::ExpectationNotMetError", "message" => message, "backtrace" => ["./a_spec.rb:1:in 'b'"] } }

      result = JitCatch::RSpecParser.parse(JSON.generate("examples" => [example], "summary" => {}), "", "")["tests"].fetch("A g")

      assert_equal ["expected: 1", *lines, *("got #<KeyError: k>" unless quoted.empty?)].join("\n").rstrip, result["message"]
      assert_equal [["a_spec.rb", 1], *quoted], result["backtrace"].map { |item| [item["file"], item["line"]] }
    end
  end
end
