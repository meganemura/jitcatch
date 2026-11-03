# frozen_string_literal: true

require_relative "../test_helper"

class TestRSpecParser < Minitest::Test
  RSPEC_FRAME = "/opt/ruby/lib/ruby/gems/4.0.0/gems/rspec-core-3.13.6/lib/rspec/core/example.rb:263:in 'BasicObject#instance_exec'"

  def example(id, full, status, line, exception: nil)
    {
      "id" => "./.jitcatch/calc_spec.rb[#{id}]",
      "description" => full.split(" ").last,
      "full_description" => full,
      "status" => status,
      "file_path" => "./.jitcatch/calc_spec.rb",
      "line_number" => line,
      "exception" => exception
    }.compact
  end

  def report(examples, messages: [], outside: 0)
    JSON.generate(
      "examples" => examples,
      "messages" => messages,
      "summary" => { "example_count" => examples.size, "errors_outside_of_examples_count" => outside }
    )
  end

  def test_reads_each_example_with_its_line_status_and_failure
    examples = [
      example("1:1", "Calc#add sums", "passed", 5),
      example("1:2", "Calc#add rounds", "failed", 9, exception: {
        "class" => "RSpec::Expectations::ExpectationNotMetError",
        "message" => "\nexpected: 3\n     got: 4\n\n(compared using ==)\n",
        "backtrace" => [
          "/opt/ruby/lib/ruby/gems/4.0.0/gems/rspec-support-3.13.7/lib/rspec/support.rb:110:in 'block in <module:Support>'",
          "./.jitcatch/calc_spec.rb:10:in 'block (3 levels) in <top (required)>'",
          RSPEC_FRAME,
          "-e:1:in '<main>'"
        ]
      }),
      example("1:3", "Calc#boom", "failed", 12, exception: {
        "class" => "KeyError",
        "message" => "key not found: :a in /tmp/w/head/lib",
        "backtrace" => ["/tmp/w/head/lib/calc.rb:4:in 'Calc#boom'", "./.jitcatch/calc_spec.rb:13:in 'block (2 levels)'", RSPEC_FRAME]
      }),
      example("1:4", "Calc later", "pending", 15)
    ]
    normalizer = ->(text) { text.gsub("/tmp/w/head/", "{worktree}/") }

    parsed = JitCatch::RSpecParser.parse(report(examples), "", "", normalizer: normalizer)

    assert_nil parsed["file_error"]
    assert_equal({ "Calc#add sums" => 5, "Calc#add rounds" => 9, "Calc#boom" => 12, "Calc later" => 15 }, parsed["lines"])
    tests = parsed["tests"]
    assert_equal %w[pass fail error skip], tests.values_at("Calc#add sums", "Calc#add rounds", "Calc#boom", "Calc later").map { |test| test["status"] }
    assert_equal({
      "status" => "fail",
      "error_class" => "RSpec::Expectations::ExpectationNotMetError",
      "message" => "expected: 3\n     got: 4\n\n(compared using ==)",
      "message_first_line" => "expected: 3",
      "backtrace" => [{ "file" => ".jitcatch/calc_spec.rb", "line" => 10 }],
      "cause" => nil
    }, tests["Calc#add rounds"])
    boom = tests["Calc#boom"]
    assert_equal ["KeyError", "key not found: :a in {worktree}/lib"], [boom["error_class"], boom["message"]]
    assert_equal [{ "file" => "lib/calc.rb", "line" => 4 }, { "file" => ".jitcatch/calc_spec.rb", "line" => 13 }], boom["backtrace"]
  end

  def test_drops_the_backtrace_and_its_header_from_a_raise_error_message
    message = "expected KeyError, got #<ArgumentError: wrong number of arguments (given 1, expected 2)> with backtrace:\n  # ./lib/calc.rb:1:in 'Calc#add'\n  # #{RSPEC_FRAME}"
    examples = [example("1:1", "Calc raises", "failed", 3, exception: { "class" => "RSpec::Expectations::ExpectationNotMetError", "message" => message, "backtrace" => [] })]

    result = JitCatch::RSpecParser.parse(report(examples), "", "")["tests"].fetch("Calc raises")

    assert_equal "expected KeyError, got #<ArgumentError: wrong number of arguments (given 1, expected 2)>", result["message"]
  end

  def test_an_error_with_a_cause_names_the_cause_and_keeps_only_its_own_frames
    backtrace = ["./lib/calc.rb:2:in 'Object#g'", "./.jitcatch/calc_spec.rb:5:in 'block (2 levels)'", RSPEC_FRAME,
                 "------------------", "--- Caused by: ---", "KeyError:", "  inner k", "  more", "  ./lib/calc.rb:2:in 'Object#g'"]
    examples = [example("1:1", "Calc errors", "failed", 5, exception: { "class" => "W", "message" => "outer", "backtrace" => backtrace })]

    result = JitCatch::RSpecParser.parse(report(examples), "", "")["tests"].fetch("Calc errors")

    assert_equal({ "error_class" => "KeyError", "message" => "inner k\nmore" }, result["cause"])
    assert_equal [{ "file" => "lib/calc.rb", "line" => 2 }, { "file" => ".jitcatch/calc_spec.rb", "line" => 5 }], result["backtrace"]
    assert_nil JitCatch::RSpecParser.parse(report([example("1:1", "Calc errors", "failed", 5, exception: { "class" => "W", "message" => "outer", "backtrace" => [] })]), "", "")["tests"].fetch("Calc errors")["cause"]
  end

  def test_a_mock_failure_and_a_fixed_pending_are_failures
    examples = [
      example("1:1", "A mock", "failed", 3, exception: { "class" => "RSpec::Mocks::MockExpectationError", "message" => "expected: 1 time", "backtrace" => [] }),
      example("1:2", "A fixed", "failed", 4, exception: { "class" => "RSpec::Core::Pending::PendingExampleFixedError", "message" => "Expected pending 'x' to fail.", "backtrace" => [] }),
      example("1:3", "A multiple", "failed", 5, exception: { "class" => "RSpec::Expectations::MultipleExpectationsNotMetError", "message" => "Got 2 failures", "backtrace" => [] })
    ]

    tests = JitCatch::RSpecParser.parse(report(examples), "", "")["tests"]

    assert_equal %w[fail fail fail], tests.values.map { |test| test["status"] }
  end

  def test_an_error_while_loading_the_file_is_a_file_error
    message = "\nAn error occurred while loading ./.jitcatch/calc_spec.rb.\nFailure/Error: require \"nope\"\n\nLoadError:\n  cannot load such file -- nope\n# ./.jitcatch/calc_spec.rb:1:in 'Kernel#require'\n# -e:1:in '<main>'\n"

    parsed = JitCatch::RSpecParser.parse(report([], messages: [message, "No examples found."], outside: 1), "", "")

    assert_equal({}, parsed["tests"])
    assert_equal({
      "status" => "error",
      "error_class" => "LoadError",
      "message" => "cannot load such file -- nope",
      "message_first_line" => "cannot load such file -- nope",
      "backtrace" => [{ "file" => ".jitcatch/calc_spec.rb", "line" => 1 }],
      "cause" => nil
    }, parsed["file_error"])
  end

  def test_a_missing_report_falls_back_to_the_process_output
    parsed = JitCatch::RSpecParser.parse(nil, "", "-e:1:in 'Kernel#require': cannot load such file -- rspec/core (LoadError)\n")

    assert_equal ["LoadError", "-e:1:in 'Kernel#require': cannot load such file -- rspec/core (LoadError)"], parsed["file_error"].values_at("error_class", "message")
  end

  def test_two_examples_with_one_description_keep_both_rows
    examples = [example("1:1", "Calc works", "passed", 3), example("1:2", "Calc works", "failed", 7, exception: { "class" => "RuntimeError", "message" => "x", "backtrace" => [] })]

    parsed = JitCatch::RSpecParser.parse(report(examples), "", "")

    assert_equal({ "Calc works" => 3, "Calc works (line 7)" => 7 }, parsed["lines"])
    assert_equal %w[pass error], parsed["tests"].values.map { |test| test["status"] }
  end

  def test_a_report_that_is_not_an_object_falls_back_to_stdout
    parsed = JitCatch::RSpecParser.parse("[]", "boom (RuntimeError)\n", "")

    assert_equal ["RuntimeError", "boom (RuntimeError)"], parsed["file_error"].values_at("error_class", "message")
  end

  def test_a_file_with_no_examples_and_no_error_has_no_rows_and_no_file_error
    assert_equal({ "tests" => {}, "lines" => {}, "file_error" => nil }, JitCatch::RSpecParser.parse(report([], messages: ["No examples found."]), "", ""))
  end

  def test_an_outside_error_without_a_class_line_keeps_its_text
    parsed = JitCatch::RSpecParser.parse(report([], messages: ["something broke in a hook"], outside: 1), "", "")

    assert_equal ["RuntimeError", "something broke in a hook"], parsed["file_error"].values_at("error_class", "message")
  end
end
