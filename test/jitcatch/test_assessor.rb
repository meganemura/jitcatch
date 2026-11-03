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
        candidate("t02", "AddTest#test_arity", ["add"], error("ArgumentError", "wrong number of arguments (given 2, expected 3)"), frames("lib/calc.rb", 11) + frames(".jitcatch/addtest.rb", 5)),
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

    out = JitCatch::Assessor.apply(doc)
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

    downstream = {
      "methods" => [
        {
          "id" => "m02", "change" => "added", "signature" => "added", "bare_name" => "coupon_discount_cents",
          "name" => "Shop::Cart#coupon_discount_cents", "file" => "lib/shop/cart.rb",
          "start_line" => 38, "end_line" => 47,
          "reachable_from" => ["Shop::Cart#tax_cents", "Shop::Cart#taxable_cents", "Shop::Cart#total_cents"]
        },
        {
          "id" => "m04", "change" => "modified", "signature" => "same", "bare_name" => "taxable_cents",
          "name" => "Shop::Cart#taxable_cents", "file" => "lib/shop/cart.rb",
          "start_line" => 56, "end_line" => 59,
          "reachable_from" => ["Shop::Cart#tax_cents", "Shop::Cart#total_cents"]
        },
        {
          "id" => "m05", "change" => "modified", "signature" => "same", "bare_name" => "volume_discount_cents",
          "name" => "Shop::Cart#volume_discount_cents", "file" => "lib/shop/cart.rb",
          "start_line" => 50, "end_line" => 54,
          "reachable_from" => ["Shop::Cart#tax_cents", "Shop::Cart#taxable_cents", "Shop::Cart#total_cents"]
        }
      ],
      "constants" => [],
      "tests" => [
        candidate("t01", "TotalTest#test_at_threshold", ["total_cents"], failure("Expected: 9720\n  Actual: 10800"))
      ]
    }
    pointed = JitCatch::Assessor.apply(downstream)
    assert_equal "m05", pointed["tests"].fetch(0)["method_id"]
    assert_includes pointed["tests"].fetch(0)["tags"], "touches:unchanged_caller"
    assert_equal({
      "generated" => 9,
      "no_signal" => 1,
      "fail_on_base" => 0,
      "candidates" => 8,
      "flaky" => 0,
      "discarded" => 5,
      "reported" => 3
    }, out["counts"])

    again = JitCatch::Assessor.apply(out)
    assert_equal out["tests"].map { |test| test["tags"] }, again["tests"].map { |test| test["tags"] }
    assert_equal out["counts"], again["counts"]
  end

  def test_a_constructor_mention_ranks_below_a_named_method_and_a_caller
    doc = {
      "methods" => [
        method("m01", "modified", "same", "initialize", [], 1),
        method("m02", "modified", "same", "rate", ["Calc#total"], 10)
      ],
      "constants" => [],
      "tests" => [
        candidate("t01", "RateTest#test_rate", %w[Calc.new rate], failure("Expected: 1\n  Actual: 2")),
        candidate("t02", "TotalTest#test_total", %w[Calc.new total], failure("Expected: 1\n  Actual: 2")),
        candidate("t03", "NewTest#test_new", %w[Calc.new], failure("Expected: 1\n  Actual: 2"))
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal %w[m02 m02 m01], out["tests"].map { |test| test["method_id"] }
    assert_includes out["tests"][1]["tags"], "touches:unchanged_caller"
    refute_includes out["tests"][1]["tags"], "touches:changed_method"
    assert_includes out["tests"][2]["tags"], "touches:changed_method"
  end

  def test_owner_new_names_the_constructor_of_that_owner_alone
    removed = method("m01", "removed", "removed", "initialize", [], 1).merge("name" => "QuintDriver::Mismatch#initialize")
    modified = method("m02", "modified", "same", "initialize", [], 10).merge("name" => "QuintDriver::Spec#initialize")
    doc = {
      "methods" => [removed, modified],
      "constants" => [],
      "tests" => [
        candidate("t01", "MismatchTest#test_seed", %w[Mismatch.new], failure("Expected: 1\n  Actual: 2")),
        candidate("t02", "SpecTest#test_path", %w[Spec.new], failure("Expected: 1\n  Actual: 2"))
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal [["m01", ["m01"]], ["m02", ["m02"]]], out["tests"].map { |test| test.values_at("method_id", "method_ids") }
    out["tests"].each { |test| assert_equal %w[assertion report touches:changed_method], test["tags"] }
  end

  def test_an_id_reached_only_through_unchanged_callers_is_marked_a_guess
    doc = {
      "methods" => [
        method("m01", "modified", "same", "changed_constants", ["Calc#build", "Calc.between"], 1),
        method("m02", "modified", "same", "changed_namespaces", ["Calc#build", "Calc#changed_constants", "Calc.between"], 10),
        method("m03", "modified", "same", "index_ref", ["Calc#build", "Calc.between"], 20),
        method("m04", "modified", "same", "render", ["Calc#show"], 30)
      ],
      "constants" => [],
      "tests" => [
        candidate("t01", "ChangesTest#test_visibility", %w[between build], failure("Expected: 1\n  Actual: 2")),
        candidate("t02", "ShowTest#test_show", %w[show], failure("Expected: 1\n  Actual: 2")),
        candidate("t03", "IndexTest#test_index", %w[between index_ref], failure("Expected: 1\n  Actual: 2"))
      ]
    }

    rows = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test.values_at("method_id", "method_ids", "tags")] }

    assert_equal ["m02", %w[m01 m02 m03], %w[assertion related:guess report touches:unchanged_caller]], rows["t01"]
    assert_equal ["m04", %w[m04], %w[assertion report touches:unchanged_caller]], rows["t02"]
    assert_equal ["m03", %w[m03], %w[assertion report touches:changed_method touches:unchanged_caller]], rows["t03"]
    text = JitCatch::Render.assess_text(JitCatch::Assessor.apply(doc))
    assert_includes text,
      "  c01 ChangesTest#test_visibility base=pass head=fail m02 assertion,related:guess,report,touches:unchanged_caller\n" \
      "    related guess: m02 of m01,m02,m03\n"
    assert_equal 1, text.scan("related guess:").size, "a row with one related method prints no guess line"
  end

  def test_candidate_ids_follow_test_ids_and_other_rows_carry_nulls
    stale = { "method_id" => "m09", "tags" => ["report"], "disposition" => "reported", "candidate_id" => "c09" }
    doc = {
      "methods" => [],
      "tests" => [
        candidate("t02", "BTest#test_b", [], failure("b")),
        { "id" => "t03", "name" => "CTest#test_c", "classification" => "no_signal", "base" => pass_result, "head" => pass_result }.merge(stale),
        candidate("t01", "ATest#test_a", [], failure("a")).merge(stale)
      ]
    }
    out = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test] }
    assert_equal ["c01", nil, ["assertion", "report"]], out["t01"].values_at("candidate_id", "method_id", "tags")
    assert_equal "c02", out["t02"]["candidate_id"]
    assert_equal [nil, nil, [], [], "no_signal"], %w[candidate_id method_id method_ids tags disposition].map { |key| out["t03"].fetch(key) }
  end

  def test_rules_need_the_error_class_and_the_removed_name
    doc = {
      "methods" => [
        method("m01", "removed", "removed", "gone", [], 1),
        method("m02", "modified", "changed", "resize", [], 10).merge("old_start" => 20, "old_end" => 22),
        method("m03", "modified", "same", "show", ["A#render"], 30),
        method("m04", "modified", "removed", "shrink", [], 60),
        method("m05", "modified", "changed", "scale", [], 40)
      ],
      "constants" => [],
      "tests" => [
        candidate("t01", "ShrinkTest#test_a", [], error("NoMethodError", "undefined method 'shrink' for an instance of Calc")),
        candidate("t02", "ResizeTest#test_a", [], error("NoMethodError", "undefined method 'resize' for an instance of Calc")),
        candidate("t03", "GoneTest#test_a", [], error("RuntimeError", "undefined method 'gone' for nil")),
        candidate("t04", "ScaleTest#test_a", [], error("ArgumentError", "wrong number of arguments (given 1, expected 2)"),
                  frames("lib/calc.rb", 41) + frames("lib/calc.rb", 31)),
        candidate("t05", "ShowTest#test_a", [], error("ArgumentError", "wrong number of arguments (given 1, expected 2)"),
                  frames("lib/calc.rb", 31)),
        candidate("t06", "OtherFileTest#test_a", [], failure("x"), frames("lib/other.rb", 31)),
        candidate("t07", "OldLinesTest#test_a", [], failure("x"), frames("lib/calc.rb", 21)),
        candidate("t08", "SlowTest#test_a", [], { "status" => "timeout" }),
        candidate("t09", "RenderTest#test_a", ["render"], failure("x"))
      ]
    }
    out = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], [test["method_id"], test["tags"]]] }
    assert_equal({
      "t01" => ["m04", ["discard:signature_change", "error:NoMethodError"]],
      "t02" => ["m02", ["error:NoMethodError", "report"]],
      "t03" => ["m01", ["error:RuntimeError", "report"]],
      "t04" => ["m05", ["caller:changed:lib/calc.rb:31", "error:ArgumentError", "related:guess", "report", "touches:changed_method"]],
      "t05" => ["m03", ["error:ArgumentError", "report", "touches:changed_method"]],
      "t06" => [nil, ["assertion", "report"]],
      "t07" => ["m02", ["assertion", "report", "touches:changed_method"]],
      "t08" => [nil, ["discard:timeout"]],
      "t09" => ["m03", ["assertion", "report", "touches:unchanged_caller"]]
    }, out)
  end

  # A dropped initialize leaves Exception#initialize, which Ruby defines in
  # C, so its arity error shows the caller's line first and no changed
  # method's line at all. Ruby 3.3 and 4.0 print that line again for the
  # caller's own frame, then the frame that called the caller.
  def test_an_arity_error_with_no_ruby_callee_frame_takes_the_caller_from_the_first_frame
    doc = {
      "methods" => [method("m01", "removed", "removed", "initialize", [], 1)],
      "constants" => [],
      "tests" => [
        candidate("t01", "NewTest#test_a", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames(".jitcatch/newtest.rb", 4)),
        candidate("t02", "NewTest#test_b", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames("lib/build.rb", 7)),
        candidate("t03", "NewTest#test_c", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames(".jitcatch/newtest.rb", 4) * 2),
        candidate("t04", "NewTest#test_d", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  (frames("lib/build.rb", 7) * 2) + frames(".jitcatch/newtest.rb", 9))
      ]
    }
    out = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test["tags"]] }
    assert_equal({
      "t01" => ["discard:signature_change", "error:ArgumentError", "touches:changed_method"],
      "t02" => ["caller:unchanged:lib/build.rb:7", "error:ArgumentError", "report", "touches:changed_method"],
      "t03" => ["discard:signature_change", "error:ArgumentError", "touches:changed_method"],
      "t04" => ["caller:unchanged:lib/build.rb:7", "error:ArgumentError", "report", "touches:changed_method"]
    }, out)
  end

  def test_a_keyword_or_arity_error_inside_assert_raises_is_a_signature_change
    raised = ->(message) { failure("[Unsupported] exception expected, not\nClass: <ArgumentError>\nMessage: <#{message.inspect}>\n---Backtrace---") }
    at_scale = frames(".jitcatch/scale_test.rb", 4) + frames("lib/calc.rb", 40) + frames(".jitcatch/scale_test.rb", 4)
    doc = {
      "methods" => [
        method("m01", "modified", "changed", "scale", [], 40),
        method("m02", "modified", "same", "show", [], 30)
      ],
      "constants" => [],
      "tests" => [
        candidate("t01", "ScaleTest#test_a", [], raised.call("missing keyword: :steps"), at_scale),
        candidate("t02", "ScaleTest#test_b", [], raised.call("unknown keywords: :a, :b"), at_scale),
        candidate("t03", "ScaleTest#test_c", [], raised.call("wrong number of arguments (given 1, expected 2)"), at_scale),
        candidate("t04", "ScaleTest#test_d", [], raised.call("qty must be > 0"), at_scale),
        candidate("t05", "ShowTest#test_a", [], raised.call("missing keyword: :steps"), frames("lib/calc.rb", 31)),
        candidate("t06", "ScaleTest#test_e", [], error("ArgumentError", "missing keyword: :steps"), at_scale),
        candidate("t07", "ScaleTest#test_f", [], failure("Expected: \"missing keyword: :steps\"\n  Actual: nil"), at_scale),
        candidate("t08", "PlanTest#test_a", [], raised.call("missing keyword: :steps"), frames(".jitcatch/plan_test.rb", 4) + frames("lib/calc.rb", 40) + frames("lib/plan.rb", 7) + frames(".jitcatch/plan_test.rb", 4))
      ]
    }
    rows = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test] }
    out = rows.transform_values { |test| test["disposition"] }
    assert_equal({ "t01" => "discarded", "t02" => "discarded", "t03" => "discarded", "t04" => "reported",
                   "t05" => "reported", "t06" => "discarded", "t07" => "reported", "t08" => "reported" }, out)
    assert_includes rows["t08"]["tags"], "caller:unchanged:lib/plan.rb:7"
  end

  def test_an_error_raised_inside_a_gem_does_not_touch_the_changed_method
    in_gem = frames("{ruby}/lib/ruby/gems/4.0.0/gems/rack-3.1.0/lib/rack/utils.rb", 12) + frames("lib/calc.rb", 41)
    vendored = frames(".jitcatch/scale_test.rb", 5) + frames("vendor/bundle/ruby/4.0.0/gems/json-2.9.0/lib/json.rb", 3)
    doc = {
      "methods" => [method("m01", "modified", "same", "scale", [], 40)],
      "constants" => [],
      "dependencies" => [{ "gem" => "rack", "old" => "3.0.0", "new" => "3.1.0" }],
      "tests" => [
        candidate("t01", "ScaleTest#test_a", ["scale"], error("TypeError", "no implicit conversion"), in_gem),
        candidate("t02", "ScaleTest#test_b", ["scale"], error("JSON::ParserError", "unexpected token"), vendored),
        candidate("t03", "ScaleTest#test_c", ["scale"], error("TypeError", "no implicit conversion"), frames("lib/calc.rb", 41)),
        candidate("t04", "ScaleTest#test_d", ["scale"], failure("Expected: 1\n  Actual: 2"), in_gem)
      ]
    }
    out = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test["tags"]] }
    assert_equal({
      "t01" => ["error:TypeError", "report", "touches:changed_dependency"],
      "t02" => ["error:JSON::ParserError", "report"],
      "t03" => ["error:TypeError", "report", "touches:changed_method"],
      "t04" => ["assertion", "report", "touches:changed_method"]
    }, out)
  end

  def test_a_test_that_names_a_changed_constant_touches_it
    doc = {
      "methods" => [],
      "constants" => [{ "id" => "k01", "change" => "modified", "name" => "Geo::SCALE", "bare_name" => "SCALE" }],
      "tests" => [
        candidate("t01", "GeoTest#test_a", ["SCALE"], failure("Expected: 2\n  Actual: 3")),
        candidate("t02", "GeoTest#test_b", ["scale"], failure("Expected: 2\n  Actual: 3"))
      ]
    }
    out = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test["tags"]] }
    assert_equal({ "t01" => ["assertion", "report", "touches:changed_constant"], "t02" => ["assertion", "report"] }, out)
  end

  def test_removed_constants_match_by_bare_name_full_name_or_suffix
    doc = {
      "methods" => [],
      "constants" => [
        { "id" => "k01", "change" => "removed", "name" => "Calc::OLD", "bare_name" => "OLD" },
        { "id" => "k02", "change" => "modified", "name" => "Calc::KEPT", "bare_name" => "KEPT" }
      ],
      "tests" => [
        "OLD", "Calc::OLD", "Shop::Calc::OLD", "KEPT", "Calc::KEPT", "NEW"
      ].each_with_index.map { |name, index|
        candidate(format("t%02d", index + 1), "ConstTest#test_#{index}", [], error("NameError", "uninitialized constant #{name}"))
      }
    }
    out = JitCatch::Assessor.apply(doc)["tests"].map { |test| test["disposition"] }
    assert_equal %w[discarded discarded discarded reported reported reported], out
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
