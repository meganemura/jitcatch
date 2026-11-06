# frozen_string_literal: true

require_relative "../test_helper"

class TestAssessor < Minitest::Test
  # Each checkout of a Rails app uses its own numbered test database, and
  # one that was never created fails on that side alone.
  def test_a_row_whose_message_varied_says_so_in_its_tags
    doc = {
      "methods" => [method("m01", "modified", "same", "approve!", [], 1)],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "Loan#approve! approves", ["approve!"], { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "id 1" }).merge("message_varies" => true),
        candidate("t02", "Loan#approve! refuses", ["approve!"], { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "no" })
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal [true, false], out["tests"].map { |test| test["tags"].include?("message_varies") }
  end

  # A test database made with db:create alone has no tables until something
  # loads the schema, so a missing table says nothing about the change.
  def test_discards_a_head_whose_database_has_no_tables
    doc = {
      "methods" => [method("m01", "modified", "same", "approve!", [], 1)], "constants" => [], "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "Loan#approve! pg", ["approve!"], error("ActiveRecord::StatementInvalid", "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist\nLINE 10: WHERE a.attrelid = '\"loans\"'::regclass")),
        candidate("t02", "Loan#approve! sqlite", ["approve!"], error("ActiveRecord::StatementInvalid", "SQLite3::SQLException: no such table: loans")),
        candidate("t03", "Loan#approve! sqlite columns", ["approve!"], error("ActiveRecord::StatementInvalid", "Could not find table 'loans'")),
        candidate("t04", "Loan#approve! mysql", ["approve!"], error("ActiveRecord::StatementInvalid", "Mysql2::Error: Table 'app_test.loans' doesn't exist")),
        candidate("t05", "Loan#approve! unique", ["approve!"], error("ActiveRecord::StatementInvalid", "PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint")),
        candidate("t06", "Loan#approve! own", ["approve!"], error("RuntimeError", "Could not find table 'loans'"))
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal [%w[discarded discard:no_table]] * 4 + [%w[reported report]] * 2,
      out["tests"].map { |test| [test["disposition"], test["tags"].find { |tag| tag.start_with?("discard:", "report") }] }
    assert_equal 4, out["untested"]
    fail_on_base = { "id" => "t07", "name" => "Loan#approve! opens", "file" => "candidates/loan_test.rb", "classification" => "fail_on_base",
                     "base" => error("ActiveRecord::StatementInvalid", "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist"),
                     "head" => error("ActiveRecord::StatementInvalid", "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist") }
    assert JitCatch::Assessor.untested_run?(JitCatch::Assessor.apply(doc.merge("tests" => [fail_on_base]))), "a run whose every row found no table"
  end

  # A run where the database hid some rows and the rest failed on base
  # compared no test across the change, and the cause sits outside the
  # candidates, as it does for a run whose every row the database hid. A
  # run whose rows all failed on base with a working database is the
  # candidates' to fix, and each row already says why.
  def test_a_run_that_compared_nothing_because_a_database_hid_rows_tested_nothing
    no_table = error("ActiveRecord::StatementInvalid", "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist")
    hidden = ->(id) { { "id" => id, "name" => "Loan#approve! #{id}", "file" => "candidates/loan_test.rb", "classification" => "fail_on_base", "base" => no_table, "head" => no_table } }
    wrong = { "id" => "t07", "name" => "Notify#args", "file" => "candidates/notify_test.rb", "classification" => "fail_on_base", "base" => failure("Expected: 1"), "head" => failure("Expected: 1") }
    passing = wrong.merge("classification" => "no_signal", "base" => pass_result, "head" => pass_result)
    run = ->(tests) { JitCatch::Assessor.untested_run?(JitCatch::Assessor.apply({ "methods" => [], "constants" => [], "tests_dir" => "candidates", "tests" => tests })) }
    hidden_rows = (1..6).map { |n| hidden.("t0#{n}") }

    assert run.(hidden_rows + [wrong]), "six rows found no table and the seventh failed on base"
    refute run.(hidden_rows + [passing]), "one row compared base with head"
    refute run.([wrong]), "a working database with a wrong candidate"
  end

  def test_discards_a_head_that_cannot_reach_its_database
    doc = {
      "methods" => [method("m01", "modified", "same", "approve!", [], 1)],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "Loan#approve! approves", ["approve!"], error("ActiveRecord::NoDatabaseError", "Database not found: loans_test2.")),
        candidate("t02", "Loan#approve! connects", ["approve!"], error("ActiveRecord::ConnectionNotEstablished", "connection to server failed")),
        candidate("t03", "Loan#approve! reaches", ["approve!"], error("ActiveRecord::DatabaseConnectionError", "There is an issue connecting with your hostname: 127.0.0.1.")),
        candidate("t04", "Loan#approve! refuses", ["approve!"], error("ActiveRecord::RecordInvalid", "Validation failed"))
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal [%w[discarded discard:no_database]] * 3 + [%w[reported report]],
      out["tests"].map { |test| [test["disposition"], test["tags"].find { |tag| tag.start_with?("discard:", "report") }] }
  end

  # A row that timed out or found no database on either side compared
  # nothing; a fail_on_base row whose base could not reach its database is one.
  def test_counts_the_rows_that_did_not_run_to_a_result_on_both_sides
    no_database = error("ActiveRecord::NoDatabaseError", "Database not found: loans_test1.")
    doc = {
      "methods" => [method("m01", "modified", "same", "approve!", [], 1)], "constants" => [], "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "Loan#approve! approves", ["approve!"], timeout_result),
        { "id" => "t02", "name" => "Loan#approve! opens", "file" => "candidates/loan_test.rb", "classification" => "fail_on_base",
          "base" => no_database.merge("status" => "error"), "head" => { "status" => "pass" } },
        candidate("t03", "Loan#approve! reaches", ["approve!"], error("ActiveRecord::ConnectionNotEstablished", "connection to server failed"))
      ]
    }

    assert_equal 3, JitCatch::Assessor.apply(doc)["untested"]
    assert JitCatch::Assessor.untested_run?(JitCatch::Assessor.apply(doc)), "every row untested"
    doc["tests"] << candidate("t04", "Loan#approve! times out", ["approve!"], { "status" => "timeout" })
    assert_equal 4, JitCatch::Assessor.apply(doc)["untested"], "a timeout row that names no error class"
    doc["tests"] << candidate("t05", "Loan#approve! refuses", ["approve!"], error("ActiveRecord::RecordInvalid", "Validation failed"))
    assert_equal 4, JitCatch::Assessor.apply(doc)["untested"]
    refute JitCatch::Assessor.untested_run?(JitCatch::Assessor.apply(doc)), "one row ran to a result"
    assert_equal 0, JitCatch::Assessor.apply(doc.merge("tests" => []))["untested"]
    refute JitCatch::Assessor.untested_run?(JitCatch::Assessor.apply(doc.merge("tests" => []))), "a run with no rows"
  end

  # A base that timed out might have passed with more time, so its row
  # says nothing about the change, whatever head did.
  def test_discards_a_row_whose_base_timed_out
    timed_out = candidate("t01", "Loan#approve! approves", ["approve!"], { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1" })
    doc = {
      "methods" => [method("m01", "modified", "same", "approve!", [], 1)], "constants" => [], "tests_dir" => "candidates",
      "tests" => [timed_out.merge("base" => { "status" => "timeout", "error_class" => "Timeout" })]
    }

    test = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["discarded", "discard:timeout"], [test["disposition"], test["tags"].find { |tag| tag.start_with?("discard:") }]
  end

  # A head that runs out of the time a base needed less than half of may
  # loop or wait forever, which is the change's to answer for. A base that
  # took longer, or a run file that kept no time, leaves a slow boot as
  # likely, so the row says nothing.
  def test_reports_a_timeout_on_head_alone_when_base_passed_well_within_the_timeout
    doc = ->(base) {
      { "timeout_s" => 10, "methods" => [method("m01", "modified", "same", "wait", [], 1)], "constants" => [], "tests_dir" => "candidates",
        "tests" => [candidate("t01", "Waiter#wait", ["wait"], timeout_result).merge("base" => base)] }
    }
    outcome = ->(base) {
      out = JitCatch::Assessor.apply(doc.(base))
      test = out["tests"].fetch(0)
      [test["disposition"], test["tags"].grep(/\A(?:discard:|report\z|head_only_timeout\z)/), out["untested"]]
    }

    assert_equal ["reported", %w[head_only_timeout report], 0], outcome.(pass_result.merge("seconds" => 2.1))
    assert_equal ["reported", %w[head_only_timeout report], 0], outcome.(pass_result.merge("seconds" => 5.0)), "exactly half"
    assert_equal ["discarded", %w[discard:timeout], 1], outcome.(pass_result.merge("seconds" => 5.1))
    assert_equal ["discarded", %w[discard:timeout], 1], outcome.(pass_result), "a run file that kept no time"
  end

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
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "LabelTest#test_label", ["label"], error("NoMethodError", "undefined method `label' for Calc")),
        candidate("t02", "AddTest#test_arity", ["add"], error("ArgumentError", "wrong number of arguments (given 2, expected 3)"), frames("lib/calc.rb", 11) + frames("candidates/addtest.rb", 5)),
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
      "tests_dir" => "candidates",
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
      "tests_dir" => "candidates",
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
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "MismatchTest#test_seed", %w[Mismatch.new], failure("Expected: 1\n  Actual: 2")),
        candidate("t02", "SpecTest#test_path", %w[Spec.new], failure("Expected: 1\n  Actual: 2"))
      ]
    }

    out = JitCatch::Assessor.apply(doc)

    assert_equal [["m01", ["m01"]], ["m02", ["m02"]]], out["tests"].map { |test| test.values_at("method_id", "method_ids") }
    out["tests"].each { |test| assert_equal %w[assertion report touches:changed_method], test["tags"] }
  end

  # A save names a callback the change document lists under `run_by`,
  # and a factory names the constructor it lists under `builders`; each
  # call names only the method that lists it.
  def test_a_listed_call_mentions_the_method_it_runs
    saved = method("m01", "modified", "same", "count_save", [], 1).merge("run_by" => %w[Calc#save! Calc.create!])
    built = method("m02", "modified", "same", "initialize", [], 10).merge("builders" => %w[create(:calc)])
    doc = {
      "methods" => [saved, built],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "SaveTest#test_save", %w[Calc#save!], failure("Expected: 1\n  Actual: 2")),
        candidate("t02", "CreateTest#test_create", %w[Shop::Calc.create!], failure("Expected: 1\n  Actual: 2")),
        candidate("t03", "FactoryTest#test_factory", %w[create(:calc)], failure("Expected: 1\n  Actual: 2"))
      ]
    }

    rows = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test.values_at("method_id", "method_ids")] }

    assert_equal({ "t01" => ["m01", %w[m01]], "t02" => ["m01", %w[m01]], "t03" => ["m02", %w[m02]] }, rows)
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
      "tests_dir" => "candidates",
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
      "    related guess: Calc#changed_namespaces (m02), ranked first of 3: Calc#changed_constants (m01), Calc#changed_namespaces (m02), Calc#index_ref (m03)\n"
    assert_equal 1, text.scan("related guess:").size, "a row with one related method prints no guess line"
  end

  # `reachable_from` stops four calls up; a test of an entry point above
  # that reaches the method through `reached_by`, and a run file written
  # before `reached_by` existed still reads `reachable_from`.
  def test_a_caller_past_the_kept_ones_puts_the_method_in_the_pool
    deep = method("m01", "modified", "same", "fee", ["Calc#total"], 1).merge("reached_by" => ["Calc#total", "Calc.start"])
    near = method("m02", "modified", "same", "help", ["Calc.start"], 10)
    doc = {
      "methods" => [deep, near],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [candidate("t01", "StartTest#test_start", %w[start], failure("Expected: 4\n  Actual: 5"))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)
    assert_equal [%w[m01 m02], true], [row["method_ids"], row["tags"].include?("related:guess")]
    old = doc.merge("methods" => [deep.except("reached_by"), near])
    assert_equal %w[m02], JitCatch::Assessor.apply(old)["tests"].fetch(0)["method_ids"]
  end

  # A test that enters high reaches the plumbing near its entry point and
  # the code its assertion checks further down, so the pick is the method
  # farthest from the entry point the test calls.
  def test_a_guess_picks_the_method_farthest_from_the_entry_point
    near = method("m01", "modified", "same", "officer", ["Desk#update"], 1).merge("caller_depths" => { "Desk#update" => 1 })
    deep = method("m02", "modified", "same", "approved_cents", ["Desk#update", "Gate#check"], 10).merge("caller_depths" => { "Desk#update" => 4, "Gate#check" => 1 })
    doc = {
      "methods" => [near, deep],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [candidate("t01", "DeskTest#test_update", %w[update], failure("Expected: 422\n  Actual: 200"))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)
    assert_equal ["m02", %w[m01 m02], true], [row["method_id"], row["method_ids"], row["tags"].include?("related:guess")]
    old = doc.merge("methods" => [near.except("caller_depths"), deep.except("caller_depths")])
    assert_nil JitCatch::Assessor.apply(old)["tests"].fetch(0)["method_id"], "a run file without depths cannot tell the two apart"
  end

  # Only the id would order two methods that sit at the same depth, link
  # to the same changed code, and both existed on base, so the row names
  # the pool and no pick: an id says when a method appears in the diff,
  # not where a failure came from.
  def test_a_guess_that_only_the_id_would_settle_names_no_pick
    plumbing = method("m01", "modified", "same", "drive", ["Trace.replay"], 1).merge("caller_depths" => { "Trace.replay" => 2 })
    decode = method("m02", "modified", "same", "decode", ["Trace.replay"], 10).merge("caller_depths" => { "Trace.replay" => 2 })
    near = method("m03", "modified", "same", "check", ["Trace.replay"], 20).merge("caller_depths" => { "Trace.replay" => 1 })
    doc = {
      "base" => "1111111111111111", "head" => "2222222222222222",
      "methods" => [plumbing, decode, near],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [candidate("t01", "FramesTest#test_frames", %w[replay], failure("Expected false to be truthy."))]
    }

    out = JitCatch::Assessor.apply(doc)
    row = out["tests"].fetch(0)
    assert_equal [nil, %w[m01 m02 m03], true], [row["method_id"], row["method_ids"], row["tags"].include?("related:guess")]
    assert_includes JitCatch::Render.assess_text(out),
      "  c01 FramesTest#test_frames base=pass head=fail - assertion,related:guess,report,touches:unchanged_caller\n" \
      "    related guess: none; the test reaches 3 changed methods equally and no frame of head's failure is in one: Calc#drive (m01), Calc#decode (m02), Calc#check (m03). " \
      "Next: find what makes head's value in them, or in a changed file that holds no method, such as a view: git diff --stat 111111111111 222222222222\n"
    deeper = doc.merge("methods" => [plumbing, decode.merge("caller_depths" => { "Trace.replay" => 3 }), near])
    assert_equal "m02", JitCatch::Assessor.apply(deeper)["tests"].fetch(0)["method_id"]
  end

  # With no pick, the row's tags must not depend on which tied method has
  # the lower id: the test names Calc.new whichever id it carries.
  def test_a_row_with_no_pick_tags_a_named_method_of_its_pool_whatever_its_id
    rows = [%w[m01 m02], %w[m02 m01]].map do |constructor_id, total_id|
      doc = {
        "methods" => [
          method(constructor_id, "modified", "same", "initialize", ["Calc.run"], 1),
          method(total_id, "modified", "same", "total", ["Calc.run"], 10)
        ].sort_by { |item| item["id"] },
        "constants" => [],
        "tests_dir" => "candidates",
        "tests" => [candidate("t01", "RunTest#test_run", %w[Calc.new run], failure("Expected: 1\n  Actual: 2"))]
      }
      JitCatch::Assessor.apply(doc)["tests"].fetch(0)
    end

    assert_equal [[nil, %w[assertion related:guess report touches:changed_method touches:unchanged_caller]]] * 2,
      rows.map { |row| [row["method_id"], row["tags"]] }
  end

  def test_candidate_ids_follow_test_ids_and_other_rows_carry_nulls
    stale = { "method_id" => "m09", "tags" => ["report"], "disposition" => "reported", "candidate_id" => "c09" }
    doc = {
      "methods" => [],
      "tests_dir" => "candidates",
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
      "tests_dir" => "candidates",
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
      "t03" => [nil, ["error:RuntimeError", "report"]],
      "t04" => ["m05", ["caller:changed:lib/calc.rb:31", "error:ArgumentError", "report", "touches:changed_method"]],
      "t05" => ["m03", ["error:ArgumentError", "report", "touches:changed_method"]],
      "t06" => [nil, ["assertion", "report"]],
      "t07" => [nil, ["assertion", "report"]],
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
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "NewTest#test_a", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames("candidates/newtest.rb", 4)),
        candidate("t02", "NewTest#test_b", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames("lib/build.rb", 7)),
        candidate("t03", "NewTest#test_c", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  frames("candidates/newtest.rb", 4) * 2),
        candidate("t04", "NewTest#test_d", %w[Calc.new], error("ArgumentError", "wrong number of arguments (given 2, expected 0..1)"),
                  (frames("lib/build.rb", 7) * 2) + frames("candidates/newtest.rb", 9))
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

  # A Data or Struct class takes its members as keywords, and Ruby defines
  # that `new` in C, so a member the change added fails the test's own
  # call with no frame of the class. That row says the candidate predates
  # head, not that head regressed; a call from the app's code still might.
  def test_a_call_the_test_wrote_to_a_changed_data_class_is_out_of_date_with_head
    doc = {
      "base" => "1111111111111111", "head" => "2222222222222222",
      "methods" => [method("m01", "removed", "removed", "label", [], 1), method("m02", "modified", "changed", "add", [], 10)],
      "constants" => [{ "id" => "k01", "change" => "modified", "name" => "Calc::Record", "bare_name" => "Record", "file" => "lib/calc.rb", "start_line" => 30 }],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "RecordTest#test_a", %w[Record], error("ArgumentError", "missing keyword: :media"), frames("candidates/recordtest.rb", 5) * 2),
        candidate("t02", "RecordTest#test_b", %w[Record build], error("ArgumentError", "missing keyword: :media"), frames("lib/build.rb", 7) + frames("candidates/recordtest.rb", 9)),
        candidate("t03", "RecordTest#test_c", %w[Record], failure("Expected: 1\n  Actual: 2")),
        candidate("t04", "LabelTest#test_a", ["label"], error("NoMethodError", "undefined method 'label' for an instance of Calc"), frames("candidates/labeltest.rb", 3)),
        candidate("t05", "AddTest#test_a", ["add"], error("ArgumentError", "wrong number of arguments (given 2, expected 3)"), frames("lib/calc.rb", 11) + frames("candidates/addtest.rb", 5))
      ]
    }

    out = JitCatch::Assessor.apply(doc)
    rows = out["tests"].to_h { |test| [test["id"], [test["disposition"], test["out_of_date"]]] }

    assert_equal({
      "t01" => ["discarded", { "id" => "k01", "name" => "Calc::Record", "change" => "definition", "call" => "candidates/recordtest.rb:5" }],
      "t02" => ["reported", nil],
      "t03" => ["reported", nil],
      "t04" => ["discarded", { "id" => "m01", "name" => "Calc#label", "change" => "removed", "call" => "candidates/labeltest.rb:3" }],
      "t05" => ["discarded", { "id" => "m02", "name" => "Calc#add", "change" => "parameters", "call" => "candidates/addtest.rb:5" }]
    }, rows)
    text = JitCatch::Render.assess_text(out)
    assert_includes text, "  c01 RecordTest#test_a base=pass head=error - discard:signature_change,error:ArgumentError,touches:changed_constant\n" \
                          "    candidate is out of date with head: Calc::Record (k01) changed its definition; update the call at candidates/recordtest.rb:5 to head's code, or drop the test\n" \
                          "    missing keyword: :media\n"
    assert_includes text, "    candidate is out of date with head: Calc#label (m01) was removed; update the call at candidates/labeltest.rb:3 to head's code, or drop the test\n"
    assert_includes text, "    candidate is out of date with head: Calc#add (m02) changed its parameters; update the call at candidates/addtest.rb:5 to head's code, or drop the test\n"
    assert_equal 3, text.scan("out of date").size, "a row head broke from the app's own code is not out of date"
  end

  def test_a_keyword_or_arity_error_inside_assert_raises_is_a_signature_change
    raised = ->(message) { failure("[Unsupported] exception expected, not\nClass: <ArgumentError>\nMessage: <#{message.inspect}>") }
    at_scale = frames("candidates/scale_test.rb", 4) + frames("lib/calc.rb", 40) + frames("candidates/scale_test.rb", 4)
    doc = {
      "methods" => [
        method("m01", "modified", "changed", "scale", [], 40),
        method("m02", "modified", "same", "show", [], 30)
      ],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "ScaleTest#test_a", [], raised.call("missing keyword: :steps"), at_scale),
        candidate("t02", "ScaleTest#test_b", [], raised.call("unknown keywords: :a, :b"), at_scale),
        candidate("t03", "ScaleTest#test_c", [], raised.call("wrong number of arguments (given 1, expected 2)"), at_scale),
        candidate("t04", "ScaleTest#test_d", [], raised.call("qty must be > 0"), at_scale),
        candidate("t05", "ShowTest#test_a", [], raised.call("missing keyword: :steps"), frames("lib/calc.rb", 31)),
        candidate("t06", "ScaleTest#test_e", [], error("ArgumentError", "missing keyword: :steps"), at_scale),
        candidate("t07", "ScaleTest#test_f", [], failure("Expected: \"missing keyword: :steps\"\n  Actual: nil"), at_scale),
        candidate("t08", "PlanTest#test_a", [], raised.call("missing keyword: :steps"), frames("candidates/plan_test.rb", 4) + frames("lib/calc.rb", 40) + frames("lib/plan.rb", 7) + frames("candidates/plan_test.rb", 4))
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
    vendored = frames("candidates/scale_test.rb", 5) + frames("vendor/bundle/ruby/4.0.0/gems/json-2.9.0/lib/json.rb", 3)
    doc = {
      "methods" => [method("m01", "modified", "same", "scale", [], 40)],
      "constants" => [],
      "dependencies" => [{ "gem" => "rack", "old" => "3.0.0", "new" => "3.1.0" }],
      "tests_dir" => "candidates",
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
      "tests_dir" => "candidates",
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
      "tests_dir" => "candidates",
      "tests" => [
        "OLD", "Calc::OLD", "Shop::Calc::OLD", "KEPT", "Calc::KEPT", "NEW"
      ].each_with_index.map { |name, index|
        candidate(format("t%02d", index + 1), "ConstTest#test_#{index}", [], error("NameError", "uninitialized constant #{name}"))
      }
    }
    out = JitCatch::Assessor.apply(doc)["tests"].map { |test| test["disposition"] }
    assert_equal %w[discarded discarded discarded reported reported reported], out
  end

  # A call the test sends to a named class reaches only what that class's
  # method reaches, and a changed method it names is not its own caller.
  def test_a_named_receiver_picks_the_callees_of_its_class_s_method
    doc = {
      "methods" => [
        method("m01", "modified", "same", "loud", ["Emit.render"], 1).merge("name" => "Fancy.loud"),
        method("m02", "modified", "same", "plain", ["Plain.render"], 10).merge("name" => "Plain.plain"),
        method("m03", "modified", "same", "render", [], 20).merge("name" => "Index.render")
      ],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "EmitTest#test_render", %w[Emit.render render], failure("x")),
        candidate("t02", "IndexTest#test_render", %w[Index.render render], failure("x")),
        { "id" => "t03", "file" => "ok_test.rb", "name" => "OkTest#test_ok", "mentions" => %w[Emit.render render], "classification" => "no_signal",
          "base" => pass_result, "head" => pass_result }
      ]
    }

    rows = JitCatch::Assessor.apply(doc)["tests"].to_h { |test| [test["id"], test.values_at("method_id", "method_ids", "tags")] }

    assert_equal ["m01", %w[m01], %w[assertion report touches:unchanged_caller]], rows["t01"]
    assert_equal ["m03", %w[m03], %w[assertion report touches:changed_method]], rows["t02"]
    assert_equal({ "dynamic_call" => nil }, JitCatch::Assessor.apply(doc)["tests"].fetch(2).slice("dynamic_call"))
  end

  # From quint_driver's history: a test names Quint.simulate, to make the
  # traces, and Trace.replay, the call it checks. Only replay reaches the
  # changed code below it.
  def test_a_guess_between_named_methods_picks_the_one_above_more_changed_code
    named = ->(id, bare) { method(id, "modified", "same", bare, [], 0).merge("name" => "Q.#{bare}") }
    below = ->(id, change, bare, reachable) { method(id, change, "same", bare, reachable, 0).merge("name" => "A.#{bare}") }
    doc = {
      "methods" => [
        below.call("m02", "modified", "drive", ["Q.replay"]),
        below.call("m04", "added", "raised_in", ["A.drive", "Q.replay"]),
        named.call("m05", "simulate"),
        named.call("m06", "replay")
      ],
      "constants" => [],
      "tests" => [candidate("t01", "StepErrorTest#test_names_no_frame", ["Q.replay", "Q.simulate", "replay", "simulate"], failure("Expected: 1\n  Actual: 2"))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["m06", %w[m05 m06]], row.values_at("method_id", "method_ids")
  end

  def test_a_guess_passes_over_an_edit_that_only_forwards_to_an_added_method
    doc = {
      "methods" => [
        method("m01", "modified", "same", "total", [], 1).merge("forwards_to_added" => true),
        method("m02", "modified", "same", "label", [], 10)
      ],
      "constants" => [],
      "tests" => [candidate("t01", "LabelTest#test_text", %w[label total], failure("Expected: 1\n  Actual: 2"))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["m02", %w[m01 m02]], row.values_at("method_id", "method_ids")
  end

  # A moved method's old lines count in the file it came from, not in the
  # file a frame names.
  def test_a_frame_on_the_old_lines_of_a_moved_method_does_not_hit_it
    doc = {
      "methods" => [
        method("m01", "moved", "same", "total", [], 20).merge("old_start" => 1, "old_end" => 3, "moved_from" => "lib/old.rb"),
        method("m02", "modified", "same", "label", [], 2)
      ],
      "constants" => [],
      "tests" => [candidate("t01", "LabelTest#test_text", %w[label total], error("RuntimeError", "boom"), frames("lib/calc.rb", 3))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["m02", %w[m02]], row.values_at("method_id", "method_ids")
  end

  # A frame of the head run names a line of head's file. Lines 5 to 7 held
  # `boot` and `fetch` on base, and hold the added `guard` on head.
  def test_a_frame_hits_the_method_head_has_on_its_line
    doc = {
      "methods" => [
        method("m01", "modified", "same", "boot", [], 20).merge("old_start" => 5, "old_end" => 7),
        method("m02", "added", "added", "guard", [], 5),
        method("m03", "removed", "removed", "fetch", [], 6)
      ],
      "constants" => [],
      "tests" => [candidate("t01", "BootTest#test_a", %w[boot], error("RuntimeError", "boom"), frames("lib/calc.rb", 6) + frames("lib/calc.rb", 21))]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["m02", %w[m02]], row.values_at("method_id", "method_ids")
  end

  def test_an_assertion_that_quotes_a_missing_name_is_not_a_name_error
    doc = {
      "methods" => [
        method("m01", "modified", "same", "label", [], 1),
        method("m02", "removed", "removed", "total", [], 10)
      ],
      "constants" => [],
      "tests_dir" => "candidates",
      "tests" => [
        candidate("t01", "LabelTest#test_text", ["label"], failure("Expected: \"ok\"\n  Actual: \"undefined method 'total' for nil\""))
      ]
    }

    row = JitCatch::Assessor.apply(doc)["tests"].fetch(0)

    assert_equal ["m01", ["m01"], "reported"], row.values_at("method_id", "method_ids", "disposition")
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
