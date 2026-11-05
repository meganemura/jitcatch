# frozen_string_literal: true

require_relative "../test_helper"

class TestMinitestParser < Minitest::Test
  def test_parses_failures_and_errors
    report = minitest_report(
      ["DemoTest#test_fail", "F", <<~TEXT],
        Failure:
        DemoTest#test_fail [/tmp/work/base/.jitcatch/demo_test.rb:9]:
        Expected: 1
          Actual: 2
      TEXT
      ["DemoTest#test_arity", "E", <<~TEXT],
        Error:
        DemoTest#test_arity:
        ArgumentError: wrong number of arguments (given 3, expected 0..2)
            /tmp/work/base/lib/calc.rb:21:in `split'
            /tmp/work/base/.jitcatch/demo_test.rb:21:in `test_arity'
      TEXT
      ["DemoTest#test_ok", ".", ""],
      ["DemoTest#test_later", "S", "Skipped:\nDemoTest#test_later [/tmp/work/base/.jitcatch/demo_test.rb:30]:\nlater\n"]
    )

    parsed = JitCatch::MinitestParser.parse(report, "", "", normalizer: ->(text) { text.gsub("/tmp/work/base/", "{worktree}/") })
    assert parsed["summary"]
    assert_nil parsed["file_error"]
    assert_equal %w[pass skip], parsed["tests"].values_at("DemoTest#test_ok", "DemoTest#test_later").map { |result| result["status"] }

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

  def test_load_error_without_a_report
    stderr = "/tmp/work/head/.jitcatch/bad_test.rb:1:in `require': cannot load such file -- nope (LoadError)\n"
    parsed = JitCatch::MinitestParser.parse(nil, "", stderr, normalizer: ->(text) { text.gsub("/tmp/work/head/", "{worktree}/") })
    refute parsed["summary"]
    assert_equal "LoadError", parsed["file_error"]["error_class"]
    assert_equal ".jitcatch/bad_test.rb", parsed["file_error"]["backtrace"].first["file"]
    assert_equal "{worktree}/.jitcatch/bad_test.rb:1:in `require': cannot load such file -- nope (LoadError)", parsed["file_error"]["message"]
  end

  def test_a_run_that_stopped_keeps_the_results_it_reported
    long = (1..25).map { |n| "line #{n}" }.join("\n")
    report = minitest_report(["DemoTest#test_ok", ".", ""], ["DemoTest#test_long", "F", "Failure:\nDemoTest#test_long:\n#{long}\n"], finished: false)
    parsed = JitCatch::MinitestParser.parse(report, "", "killed (SignalException)\n")
    assert_equal ["pass", nil], parsed["tests"]["DemoTest#test_ok"].values_at("status", "error_class")
    assert_equal (1..20).map { |n| "line #{n}" }.join("\n"), parsed["tests"]["DemoTest#test_long"]["message"]
    assert_equal ["DemoTest#test_ok", "DemoTest#test_long"], parsed["tests"].keys
    refute parsed["summary"]
    assert_equal "SignalException", parsed["file_error"]["error_class"]
  end

  def test_file_errors_from_each_stream
    {
      ["", "cannot load such file -- nope\n"] => "LoadError",
      ["", "x.rb:3: syntax error, unexpected end-of-input\n"] => "SyntaxError",
      ["boom (KeyError)\n", ""] => "KeyError",
      ["", "something broke\n"] => "RuntimeError"
    }.each do |(stdout, stderr), error_class|
      assert_equal error_class, JitCatch::MinitestParser.parse(nil, stdout, stderr)["file_error"]["error_class"], stderr + stdout
    end
    silent = JitCatch::MinitestParser.parse(nil, "", "")
    assert_equal [{}, false, "minitest summary not found"], [silent["tests"], silent["summary"], silent["file_error"]["message"]]
  end

  def test_an_assert_raises_message_keeps_no_backtrace_header
    report = minitest_report(["ArTest#test_raises", "F", <<~TEXT])
      Failure:
      ArTest#test_raises [/w/.jitcatch/ar_test.rb:4]:
      [KeyError] exception expected, not
      Class: <ArgumentError>
      Message: <"wrapped k">
      ---Backtrace---
      /w/lib/a.rb:2:in 'A.f'
      /w/.jitcatch/ar_test.rb:4:in 'block in ArTest#test_raises'
      ---------------
    TEXT

    result = JitCatch::MinitestParser.parse(report, "", "", normalizer: ->(text) { text.gsub("/w/", "{worktree}/") })["tests"].fetch("ArTest#test_raises")

    assert_equal %([KeyError] exception expected, not\nClass: <ArgumentError>\nMessage: <"wrapped k">), result["message"]
    assert_equal [{ "file" => ".jitcatch/ar_test.rb", "line" => 4 }, { "file" => "lib/a.rb", "line" => 2 }, { "file" => ".jitcatch/ar_test.rb", "line" => 4 }], result["backtrace"]
  end

  def test_an_error_keeps_the_error_it_was_raised_from_apart_from_its_message
    text = <<~TEXT
      Error:
      GTest#test_g:
      ArgumentError: outer
      two
      --- Caused by: ---
      KeyError: inner
      k
          lib/a.rb:1:in 'A.g'
    TEXT

    result = JitCatch::MinitestParser.parse(minitest_report(["GTest#test_g", "E", text]), "", "")["tests"].fetch("GTest#test_g")

    assert_equal ["outer\ntwo", { "error_class" => "KeyError", "message" => "inner\nk" }, [{ "file" => "lib/a.rb", "line" => 1 }]], result.values_at("message", "cause", "backtrace")
    plain = JitCatch::MinitestParser.parse(minitest_report(["GTest#test_g", "E", text.sub(/--- Caused by: ---\nKeyError: inner\nk\n/, "")]), "", "")["tests"].fetch("GTest#test_g")
    assert_equal ["outer\ntwo", nil], plain.values_at("message", "cause")
  end

  def test_a_message_line_shaped_like_a_frame_stays_in_the_message
    report = minitest_report(
      ["GTest#test_boom", "E", <<~TEXT],
        Error:
        GTest#test_boom:
        RuntimeError: x.rb:20:in 'y'
            lib/q.rb:3:in 'z'
        last
            /w/lib/g.rb:3:in 'G.boom'
            /w/.jitcatch/g_test.rb:5:in 'GTest#test_boom'
      TEXT
      ["GTest#test_line", "F", <<~TEXT]
        Failure:
        GTest#test_line [/w/.jitcatch/g_test.rb:4]:
        --- expected
        +++ actual
        @@ -1,4 +1,4 @@
         # encoding: UTF-8
         #    valid: true
        -"a
        +"x.rb:20:in 'y'
         "

      TEXT
    )

    tests = JitCatch::MinitestParser.parse(report, "", "", normalizer: ->(text) { text.gsub("/w/", "{worktree}/") })["tests"]

    error = tests.fetch("GTest#test_boom")
    assert_equal ["RuntimeError", "x.rb:20:in 'y'\n    lib/q.rb:3:in 'z'\nlast"], error.values_at("error_class", "message")
    assert_equal [{ "file" => "lib/g.rb", "line" => 3 }, { "file" => ".jitcatch/g_test.rb", "line" => 5 }], error["backtrace"]
    failure = tests.fetch("GTest#test_line")
    assert_equal %(-"a\n+"x.rb:20:in 'y'\n "), failure["message"].lines.last(3).join
    assert_equal [{ "file" => ".jitcatch/g_test.rb", "line" => 4 }], failure["backtrace"]
  end
end
