# frozen_string_literal: true

require_relative "../test_helper"

class TestAssessor < Minitest::Test
  def test_discards_signature_load_and_timeout_and_tags_touches
    doc = {
      "methods" => [
        method("m01", "removed", "removed", "label", [], 1),
        method("m02", "modified", "changed", "add", [], 10),
        method("m03", "modified", "same", "double", ["Calc#total"], 20)
      ],
      "constants" => [
        { "id" => "k01", "change" => "removed", "name" => "Calc::OLD", "bare_name" => "OLD" }
      ],
      "tests" => [
        candidate("t01", "LabelTest#test_label", ["label"], error("NoMethodError", "undefined method `label' for Calc")),
        candidate("t02", "AddTest#test_arity", ["add"], error("ArgumentError", "wrong number of arguments (given 2, expected 3)"), frames("lib/calc.rb", 11)),
        candidate("t03", "GuardTest#test_qty", ["add"], error("ArgumentError", "qty must be > 0")),
        candidate("t04", "LoadTest#test_load", [], error("LoadError", "cannot load such file -- shop")),
        candidate("t05", "SlowTest#test_slow", [], timeout_result),
        candidate("t06", "DoubleTest#test_double", ["double"], failure("Expected: 4\n  Actual: 5")),
        candidate("t07", "TotalTest#test_total", ["total"], failure("Expected: 4\n  Actual: 9")),
        candidate("t08", "ConstTest#test_old", ["OLD"], error("NameError", "uninitialized constant Calc::OLD")),
        { "id" => "t09", "file" => "ok_test.rb", "name" => "OkTest#test_ok", "mentions" => [], "classification" => "no_signal",
          "base" => pass_result, "head" => pass_result }
      ]
    }

    out = JitTest::Assessor.apply(doc)
    by_name = out["tests"].to_h { |test| [test["name"], test] }

    assert_equal "discarded", by_name["LabelTest#test_label"]["disposition"]
    assert_includes by_name["LabelTest#test_label"]["tags"], "discard:signature_change"

    assert_equal "discarded", by_name["AddTest#test_arity"]["disposition"]
    assert_equal "m02", by_name["AddTest#test_arity"]["method_id"]
    assert_includes by_name["AddTest#test_arity"]["tags"], "discard:signature_change"

    assert_equal "reported", by_name["GuardTest#test_qty"]["disposition"]
    assert_includes by_name["GuardTest#test_qty"]["tags"], "error:ArgumentError"
    refute_includes by_name["GuardTest#test_qty"]["tags"], "discard:signature_change"

    assert_equal "discarded", by_name["LoadTest#test_load"]["disposition"]
    assert_includes by_name["LoadTest#test_load"]["tags"], "discard:load_error"
    assert_equal "discarded", by_name["SlowTest#test_slow"]["disposition"]
    assert_includes by_name["SlowTest#test_slow"]["tags"], "discard:timeout"

    double = by_name["DoubleTest#test_double"]
    assert_equal "reported", double["disposition"]
    assert_equal "m03", double["method_id"]
    assert_includes double["tags"], "touches:changed_method"
    assert_includes double["tags"], "assertion"

    total = by_name["TotalTest#test_total"]
    assert_equal "reported", total["disposition"]
    assert_equal "m03", total["method_id"]
    assert_includes total["tags"], "touches:unchanged_caller"

    assert_equal "discarded", by_name["ConstTest#test_old"]["disposition"]
    assert_equal "no_signal", by_name["OkTest#test_ok"]["disposition"]
    assert_equal({
      "generated" => 9,
      "no_signal" => 1,
      "fail_on_base" => 0,
      "candidates" => 8,
      "flaky" => 0,
      "discarded" => 5,
      "reported" => 3
    }, out["counts"])

    again = JitTest::Assessor.apply(out)
    assert_equal out["tests"].map { |test| test["tags"] }, again["tests"].map { |test| test["tags"] }
    assert_equal out["counts"], again["counts"]
  end

  def method(id, change, signature, bare, reachable, start_line)
    {
      "id" => id,
      "change" => change,
      "signature" => signature,
      "bare_name" => bare,
      "name" => "Calc##{bare}",
      "file" => "lib/calc.rb",
      "start_line" => start_line,
      "end_line" => start_line + 2,
      "reachable_from" => reachable
    }
  end

  def candidate(id, name, mentions, head, extra_frames = nil)
    head = head.merge("backtrace" => extra_frames) if extra_frames
    {
      "id" => id,
      "file" => "#{name.split("#").first.downcase}.rb",
      "name" => name,
      "mentions" => mentions,
      "classification" => "candidate",
      "base" => pass_result,
      "head" => head
    }
  end

  def pass_result
    { "status" => "pass", "error_class" => nil, "message" => "", "message_first_line" => "", "backtrace" => [] }
  end

  def error(klass, message)
    { "status" => "error", "error_class" => klass, "message" => message, "message_first_line" => message, "backtrace" => [] }
  end

  def failure(message)
    { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => message, "message_first_line" => message.lines.first.strip, "backtrace" => [] }
  end

  def timeout_result
    { "status" => "timeout", "error_class" => "Timeout", "message" => "timeout", "message_first_line" => "timeout", "backtrace" => [] }
  end

  def frames(file, line)
    [{ "file" => file, "line" => line }]
  end
end
