# frozen_string_literal: true

require_relative "../test_helper"

class TestMinitestParser < Minitest::Test
  def test_parses_verbose_failures_and_errors
    stdout = <<~OUT
      Run options: -v --seed 1

      # Running:

      DemoTest#test_fail = 0.00 s = F
      DemoTest#test_arity = 0.00 s = E
      DemoTest#test_ok = 0.00 s = .

      Finished in 0.001041s, 5762.3492 runs/s, 1920.7831 assertions/s.

        1) Failure:
      DemoTest#test_fail [/tmp/work/base/.jitcatch/demo_test.rb:9]:
      Expected: 1
        Actual: 2

        2) Error:
      DemoTest#test_arity:
      ArgumentError: wrong number of arguments (given 3, expected 0..2)
          /tmp/work/base/lib/calc.rb:21:in `split'
          /tmp/work/base/.jitcatch/demo_test.rb:21:in `test_arity'

      3 runs, 2 assertions, 1 failures, 1 errors, 0 skips
    OUT

    parsed = JitCatch::MinitestParser.parse(stdout, "", normalizer: ->(text) { text.gsub("/tmp/work/base/", "") })
    assert parsed["summary"]
    assert_nil parsed["file_error"]
    assert_equal "pass", parsed["tests"]["DemoTest#test_ok"]["status"]

    failure = parsed["tests"]["DemoTest#test_fail"]
    assert_equal "fail", failure["status"]
    assert_equal "Minitest::Assertion", failure["error_class"]
    assert_equal "Expected: 1", failure["message_first_line"]
    assert_equal ".jitcatch/demo_test.rb", failure["backtrace"].first["file"]

    error = parsed["tests"]["DemoTest#test_arity"]
    assert_equal "error", error["status"]
    assert_equal "ArgumentError", error["error_class"]
    assert_equal "wrong number of arguments (given 3, expected 0..2)", error["message_first_line"]
    assert_equal "lib/calc.rb", error["backtrace"].first["file"]
    assert_equal 21, error["backtrace"].first["line"]
  end

  def test_load_error_without_summary
    stderr = "/tmp/work/head/.jitcatch/bad_test.rb:1:in `require': cannot load such file -- nope (LoadError)\n"
    parsed = JitCatch::MinitestParser.parse("", stderr, normalizer: ->(text) { text.gsub("/tmp/work/head/", "") })
    refute parsed["summary"]
    assert_equal "LoadError", parsed["file_error"]["error_class"]
    assert_equal ".jitcatch/bad_test.rb", parsed["file_error"]["backtrace"].first["file"]
  end
end
