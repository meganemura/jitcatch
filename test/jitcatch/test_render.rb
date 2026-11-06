# frozen_string_literal: true

require_relative "../test_helper"

class TestRender < Minitest::Test
  def test_assess_text_lists_each_candidate_with_its_failure_lines
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0",
      "base" => "b",
      "head" => "h",
      "tests" => [
        { "id" => "t01", "name" => "A#test_a", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1\n  Actual: 2\n  more" } },
        { "id" => "t02", "name" => "B#test_b", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "error", "error_class" => "KeyError", "message" => "key not found: x\nline 2" } },
        { "id" => "t03", "name" => "C#test_c", "classification" => "candidate", "base" => { "status" => "pass" } },
        { "id" => "t04", "name" => "D#test_d", "classification" => "no_signal", "base" => { "status" => "pass" },
          "head" => { "status" => "pass" } }
      ]
    })
    assert_equal <<~TEXT, JitCatch::Render.assess_text(doc)
      jitcatch assess
      version 0.1.0
      base b
      head h
      counts generated=4 no_signal=1 fail_on_base=0 candidates=3 flaky=0 discarded=0 reported=3
      assess:
        c01 A#test_a base=pass head=fail - assertion,report
          Expected: 1
          Actual: 2
        c02 B#test_b base=pass head=error - error:KeyError,report
          key not found: x
        c03 C#test_c base=pass head= - report
    TEXT
  end

  def test_assess_text_shows_the_changed_lines_of_a_minitest_diff
    diff = "--- expected\n+++ actual\n@@ -1,3 +1,3 @@\n \"a\n-b\n+c\n d\"\n"
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h",
      "tests" => [
        { "id" => "t01", "name" => "A#test_a", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => diff } },
        { "id" => "t02", "name" => "B#test_b", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Keys.\n#{diff}" } }
      ]
    })
    assert_equal [
      "  c01 A#test_a base=pass head=fail - assertion,report",
      "    -b",
      "    +c",
      "  c02 B#test_b base=pass head=fail - assertion,report",
      "    Keys."
    ], JitCatch::Render.assess_text(doc).split("assess:\n").last.lines(chomp: true)
  end

  def test_a_long_diff_line_shows_the_differing_hash_keys_or_the_first_differing_column
    long_hash = ->(t04) { "{" + (1..6).map { |n| %("t0#{n}" => ["m0#{n}", ["discard:signature_change", "error:ArgumentError"]]) }.join(", ").sub(%("m04"), t04) + "}" }
    expected = long_hash.call(%("m04"))
    actual = long_hash.call(%("m03")).sub(%(, "t06" => ["m06", ["discard:signature_change", "error:ArgumentError"]]), %(, "t07" => 1))
    text = "a" * 150
    diffs = {
      "t01" => "--- expected\n+++ actual\n@@ -1 +1 @@\n-#{expected}\n+#{actual}\n",
      "t02" => "--- expected\n+++ actual\n@@ -1 +1 @@\n-\"#{text}b#{text}\"\n+\"#{text}c#{text}\"\n"
    }
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h",
      "tests" => diffs.map { |id, message|
        { "id" => id, "name" => "A#test_#{id}", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => message } }
      }
    })

    window = "a" * 30
    assert_equal [
      "  c01 A#test_t01 base=pass head=fail - assertion,report",
      "    hash keys differ: \"t04\", \"t06\", \"t07\"",
      %(    -"t04" => ["m04", ["discard:signature_change", "error:ArgumentError"]]),
      %(    +"t04" => ["m03", ["discard:signature_change", "error:ArgumentError"]]),
      %(    -"t06" => ["m06", ["discard:signature_change", "error:ArgumentError"]]),
      %(    +"t07" => 1),
      "  c02 A#test_t02 base=pass head=fail - assertion,report",
      "    -...#{window}b#{window}...",
      "    +...#{window}c#{window}...",
      "        #{" " * 30}^ column 152"
    ], JitCatch::Render.assess_text(doc).split("assess:\n").last.lines(chomp: true)
    assert_equal diffs.values, JitCatch::Render.assess_json(doc)["candidates"].map { |row| row["message"] }
  end

  def test_a_long_array_diff_shows_the_elements_that_differ
    names = (1..8).map { |n| "name_number_#{n}" }
    pair = ->(expected, actual) { JitCatch::Render.message_lines({ "message" => "--- expected\n+++ actual\n@@ -1 +1 @@\n-#{expected.inspect}\n+#{actual.inspect}\n" }) }

    assert_equal ["array elements differ: [3]", %(-[3] "name_number_4"), %(+[3] "other")], pair.call(names, names.dup.tap { |list| list[3] = "other" })
    assert_equal ["array elements differ: [2], [6]", %(-[2] "name_number_3"), %(+[6] "added")], pair.call(names, (names - ["name_number_3"]).insert(6, "added"))
    many = names.map { |name| "#{name}!" }
    assert_equal "array elements differ: [0], [1], [2], [3] (+4 more)", pair.call(names, many).first
    assert_equal 9, pair.call(names, many).size
    swapped = [names[1], names[0], *names.drop(2)]
    assert_equal ["array elements differ: [0], [1]", %(-[0] "name_number_1"), %(+[1] "name_number_1")], pair.call(names, swapped)
    four = names.first(4).map { |name| "#{name}!" } + names.drop(4)
    assert_equal "array elements differ: [0], [1], [2], [3]", pair.call(names, four).first
    spaced = ->(list) { "[#{list.map(&:inspect).join(",  ")}]" }
    assert_match(/\^ column/, JitCatch::Render.changed_pair(names.inspect, spaced.call(names)).last)
    big = (1..500).to_a
    assert_equal "array elements differ: [499]", pair.call(big, big[0..-2] + [0]).first
    assert_match(/\^ column/, pair.call(big + [1], big[0..-2] + [0]).last)
  end

  def test_a_row_cuts_a_very_long_message_line_and_says_how_much_it_left_out
    long = "can't modify frozen Array: [#{(1..5000).to_a.join(", ")}]"
    lines = JitCatch::Render.message_lines({ "message" => long })

    assert_equal ["#{long[0, 150]}... (+#{long.length - 300} characters; the whole message is in --json) ...#{long[-150..]}"], lines
    assert_equal ["x" * 300], JitCatch::Render.message_lines({ "message" => "x" * 300 })
    actual = "Actual: #{"y" * 292}z"
    assert_equal ["Expected: 1", "#{actual[0, 150]}... (+1 character; the whole message is in --json) ...#{actual[-150..]}"],
      JitCatch::Render.message_lines({ "message" => "Expected: 1\n  #{actual}" })
  end

  # The end of an error a matcher got often holds what differs, after a
  # long path or a long value that both sides share.
  def test_a_cut_line_keeps_its_end
    got = "expected ArgumentError with message matching /state=pending/, got #<ArgumentError: #{"x" * 290} state=draft>"

    line = JitCatch::Render.message_lines({ "message" => got }).fetch(0)

    assert line.end_with?(" state=draft>"), line
    assert line.start_with?("expected ArgumentError with message matching /state=pending/, got #<ArgumentError: x"), line
  end

  # RSpec's have_attributes prints the record and both attribute Hashes on
  # one line, sorted by name, so the attribute that differs can sit in the
  # part a cut leaves out; the Diff under it names that attribute.
  def test_a_cut_first_line_shows_the_lines_its_diff_changed
    borrower = %(#<Borrower id: 1, name: "#{"G" * 120}", limit_cents: 50000>)
    message = <<~MESSAGE
      expected #<Loan id: 1, state: "draft"> to have attributes {amount_cents: 500, borrower: #{borrower}, id: 1, state: "pending"} but had attributes {amount_cents: 500, borrower: #{borrower}, id: 1, state: "draft"}
      Diff:
      @@ -3,4 +3,4 @@
       :borrower => #{borrower},
       :id => 1,
      -:state => "pending",
      +:state => "draft",
    MESSAGE

    lines = JitCatch::Render.message_lines({ "message" => message })

    assert_equal [%(-:state => "pending",), %(+:state => "draft",)], lines.drop(1)
    assert_match(/\Aexpected #<Loan id: 1, state: "draft"> to have attributes .*\.\.\. \(\+\d+ characters; the whole message is in --json\) \.\.\..*state: "draft"\}\z/, lines.fetch(0))
    assert_equal ["expected 1 to eq 2"], JitCatch::Render.message_lines({ "message" => "expected 1 to eq 2\nDiff:\n@@ -1 +1 @@\n-2\n+1\n" }),
      "a first line in full needs no diff"
    full = "x" * 300
    assert_equal [full], JitCatch::Render.message_lines({ "message" => "#{full}\nDiff:\n@@ -1 +1 @@\n-2\n+1\n" }), "300 characters is not cut"
    assert_equal [JitCatch::Render.cut_line("x" * 301)], JitCatch::Render.message_lines({ "message" => "#{"x" * 301}\n-not a diff line\n" }),
      "a line that starts with - outside a Diff is not a changed line"
  end

  # Minitest's first removed and first added lines are a pair only when the
  # added line replaces the removed one; otherwise a column says nothing.
  def test_two_diff_lines_that_do_not_replace_each_other_get_no_column
    long = "a" * 150
    message = "--- expected\n+++ actual\n@@ -1,3 +1,3 @@\n-\"x#{long}\n \"same\n+y#{long}\"\n"

    assert_equal ["-\"x#{"a" * 59}...", "+y#{"a" * 60}..."], JitCatch::Render.message_lines({ "message" => message })
    added_first = "--- expected\n+++ actual\n@@ -1,2 +1,2 @@\n+y#{long}\n-\"x#{long}\n"
    assert_equal ["-\"x#{"a" * 59}...", "+y#{"a" * 60}..."], JitCatch::Render.message_lines({ "message" => added_first })
    replaced = "--- expected\n+++ actual\n@@ -1,3 +1,3 @@\n-\"x#{long}\n-q\n+\"y#{long}\"\n"
    assert_equal "^ column 2", JitCatch::Render.message_lines({ "message" => replaced }).last.strip
  end

  # From a run on jitcatch itself: the two sides held a Minitest diff of
  # their own, so its lines came back as context lines.
  def test_a_context_line_that_starts_with_a_sign_is_not_a_change
    message = "--- expected\n+++ actual\n@@ -2,4 +2,5 @@\n +++ actual\n -\\\"a\n-b\n+c\n"

    assert_equal ["-b", "+c"], JitCatch::Render.message_lines({ "message" => message })
  end

  def test_the_short_forms_of_a_diff_line_at_their_bounds
    diff = ->(expected, actual) { { "message" => "--- expected\n+++ actual\n@@ -1 +1 @@\n#{expected}#{actual}" } }
    pair = ->(expected, actual) { JitCatch::Render.message_lines(diff.call("-#{expected}\n", "+#{actual}\n")) }
    long = %("#{"v" * 100}")
    hash = ->(pairs) { "{#{pairs.map { |key, value| %("#{key}" => #{value}) }.join(", ")}}" }
    window = "a" * 30
    marker = "#{" " * 34}^ column 71"

    assert_equal ["-#{"a" * 99}x"], JitCatch::Render.message_lines(diff.call("-#{"a" * 99}x\n", ""))
    assert_equal ["--- expected"], JitCatch::Render.message_lines({ "message" => "--- expected\nnot a header\n-b\n+c\n" })
    assert_equal ["-#{"a" * 99}b", "+#{"a" * 99}c"], pair.call("#{"a" * 99}b", "#{"a" * 99}c")
    assert_equal ["-...#{window}b#{window}", "+...#{window}c#{window}", marker], pair.call("#{"a" * 70}b#{window}", "#{"a" * 70}c#{window}")
    assert_equal ["-...#{window}b#{window}...", "+...#{window}c#{window}...", marker], pair.call("#{"a" * 70}b#{window}a", "#{"a" * 70}c#{window}a")
    assert_equal " ^ column 1", pair.call(hash.call("a" => long), "#{long}!").last
    assert_equal "   ^ column 3", pair.call(hash.call("a" => long, "b" => 1), hash.call("b" => 1, "a" => long)).last
    assert_equal "^ column", pair.call("{**x, #{hash.call("a" => long)[1..]}", "{**x, #{hash.call("a" => long.sub("v", "w"))[1..]}").last.strip[0, 8]
    four = %w[b c d e]
    assert_equal %(hash keys differ: "b", "c", "d", "e"), pair.call(hash.call(four.to_h { |key| [key, 1] }.merge("a" => long)), hash.call(four.to_h { |key| [key, 2] }.merge("a" => long))).first
    assert_equal %(hash keys differ: "b", "c", "d", "e" (+1 more)), pair.call(hash.call((four + ["f"]).to_h { |key| [key, 1] }.merge("a" => long)), hash.call((four + ["f"]).to_h { |key| [key, 2] }.merge("a" => long))).first
  end

  def test_a_load_report_names_the_ruby_and_gives_the_master_key_hint_only_for_a_rails_app
    failure = ->(side) { { "side" => side, "command" => "ruby -Ilib -I. candidates/a_test.rb", "stderr" => ["boom (IOError)"], "not_passed" => [] } }
    doc = { "stage" => "load", "rails_app" => false, "ruby" => { "version" => "3.3.6", "path" => "/r/bin/ruby" }, "base" => "b", "head" => "h",
            "setup_failed" => [failure.("base"), failure.("head")] }
    advice = "Run that command from the repository root with that side checked out, fix what it says (often a database, a credential, or a service the app needs at boot), and run jitcatch again."
    hint = " A file git ignores, such as config/master.key, is not in the checkouts jitcatch makes; pass its value with --env, such as RAILS_MASTER_KEY."
    lines = ->(rails_app) { JitCatch::Render.setup_failed_text(doc.merge("rails_app" => rails_app)).lines(chomp: true) }

    assert_equal ["base b", "head h", "ruby 3.3.6 /r/bin/ruby", "load base failed: ruby -Ilib -I. candidates/a_test.rb"], lines.(false)[1, 4]
    assert_equal advice, lines.(false).last
    assert_equal advice + hint, lines.(true).last
  end

  def test_run_text_names_omitted_files_and_an_empty_run
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 2, "timeout_s" => 10,
      "test_files_omitted" => 3, "tests" => [], "warnings" => ["base is not an ancestor of head"], "serial" => true,
      "env" => %w[A_VAR B_VAR], "env_unset" => %w[B_VAR]
    })
    assert_equal <<~TEXT, JitCatch::Render.run_text(doc)
      jitcatch run
      version 0.1.0
      base b
      head h
      warning: base is not an ancestor of head
      reruns 2
      timeout_s 10
      serial
      env A_VAR B_VAR
      env_unset B_VAR
      test_files_omitted 3
      tests:
        (none)
      counts generated=0 no_signal=0 fail_on_base=0 candidates=0 flaky=0 discarded=0 reported=0
      assess:
        (none)
    TEXT
  end

  # A test that failed on base says why, so its author can tell a new
  # feature from a test that does not run.
  def test_run_text_names_the_numbered_databases
    doc = { "version" => "0.1.0", "base" => "b", "head" => "h", "warnings" => [], "reruns" => 2, "timeout_s" => 60, "env" => ["DATABASE_URL"],
            "numbered_databases" => %w[app_test_1 app_test_2], "tests" => [],
            "counts" => { "generated" => 0, "no_signal" => 0, "fail_on_base" => 0, "candidates" => 0, "flaky" => 0, "discarded" => 0, "reported" => 0 } }

    assert_includes JitCatch::Render.run_text(doc), "timeout_s 60\nnumbered_databases app_test_1 app_test_2\nenv DATABASE_URL\n"
  end

  def test_run_text_prints_reruns_under_a_flaky_row_and_a_hint_under_a_timeout
    fail_line = { "status" => "fail", "error_class" => "Minitest::Assertion", "message_first_line" => "Expected: 1" }
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 2, "timeout_s" => 7, "tests" => [
        { "id" => "t01", "file" => "a_test.rb", "name" => "A#test_a", "classification" => "flaky",
          "base" => { "status" => "pass" }, "head" => fail_line, "reruns" => [fail_line, { "status" => "pass", "error_class" => nil, "message_first_line" => "" }] },
        { "id" => "t02", "file" => "b_test.rb", "name" => "b_test.rb#timeout", "classification" => "candidate",
          "base" => { "status" => "timeout" }, "head" => { "status" => "timeout" } },
        { "id" => "t03", "file" => "c_test.rb", "name" => "C#test_c", "classification" => "no_signal",
          "base" => { "status" => "pass" }, "head" => { "status" => "pass" }, "reruns" => [fail_line] },
        { "id" => "t04", "file" => "d_test.rb", "name" => "D#test_d", "classification" => "fail_on_base",
          "base" => { "status" => "error", "error_class" => "NoMethodError", "message" => "undefined method 'coupon' for an instance of Cart\n  more", "message_first_line" => "undefined method 'coupon' for an instance of Cart" },
          "head" => { "status" => "pass" } },
        { "id" => "t05", "file" => "e_test.rb", "name" => "E#test_e", "classification" => "fail_on_base",
          "base" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1\n  Actual: 2", "message_first_line" => "Expected: 1" },
          "head" => { "status" => "pass" } }
      ]
    })
    assert_includes JitCatch::Render.run_text(doc), <<~TEXT.chomp
      tests:
        t01 flaky A#test_a a_test.rb
          rerun 1: fail Minitest::Assertion Expected: 1
          rerun 2: pass
        t02 discarded b_test.rb#timeout b_test.rb
          hint: base and head timed out after 7s; raise --timeout if the file needs longer
        t03 no_signal C#test_c c_test.rb
        t04 fail_on_base D#test_d d_test.rb
          base: error NoMethodError undefined method 'coupon' for an instance of Cart
        t05 fail_on_base E#test_e e_test.rb
          base: fail Minitest::Assertion Expected: 1
            Actual: 2
      counts generated=5
    TEXT
  end

  # A name the child did not get is a likelier cause of a wait than a slow
  # file, so every timed-out row says it before it says to wait longer.
  def test_each_timed_out_row_names_what_the_child_did_not_get_before_the_timeout
    timed_out = ->(id) { { "id" => id, "file" => "#{id}_test.rb", "name" => "#{id}_test.rb#timeout", "classification" => "candidate", "base" => { "status" => "timeout" }, "head" => { "status" => "timeout" } } }
    run = { "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "env_not_passed" => %w[HTTPS_PROXY QUINT] }
    passing = { "id" => "t03", "file" => "a_test.rb", "name" => "A#test_a", "classification" => "no_signal", "base" => { "status" => "pass" }, "head" => { "status" => "pass" } }
    text = JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge("tests" => [timed_out.("t01"), timed_out.("t02"), passing])))

    hint = "    hint: base and head timed out after 10s; jitcatch did not pass HTTPS_PROXY QUINT, so add --env HTTPS_PROXY --env QUINT if the file needs them, then raise --timeout if it needs longer\n"
    assert_includes text, "  t01 discarded t01_test.rb#timeout t01_test.rb\n#{hint}  t02 discarded t02_test.rb#timeout t02_test.rb\n#{hint}  t03 no_signal A#test_a a_test.rb\ncounts generated=3"
    refute_includes text, "Rails"
    refute_includes JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge("tests" => [passing]))), "--env"
  end

  # Only a Rails app loads db/schema.rb in each new checkout, so only there
  # does a slow first boot explain a timeout.
  def test_a_timed_out_row_names_the_rails_first_boot_only_for_a_rails_app
    row = { "id" => "t01", "file" => "a_test.rb", "name" => "a_test.rb#timeout", "classification" => "candidate", "base" => { "status" => "pass" }, "head" => { "status" => "timeout" } }
    hint = ->(doc) { JitCatch::Render.run_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "tests" => [row] }.merge(doc))).lines.grep(/hint:/).first }

    assert_equal "    hint: head timed out after 10s; raise --timeout if the file needs longer\n", hint.({})
    assert_equal "    hint: head timed out after 10s; raise --timeout if the file needs longer, as a Rails app's first run in a new checkout can (it loads db/schema.rb)\n", hint.("rails_app" => true)
    assert_equal "    hint: head timed out after 10s; jitcatch did not pass DATABASE_URL, so add --env DATABASE_URL if the file needs it, then raise --timeout if it needs longer, as a Rails app's first run in a new checkout can (it loads db/schema.rb)\n",
      hint.("rails_app" => true, "env_not_passed" => %w[DATABASE_URL])
  end

  # Base's time is what tells a head that waits forever from a slow boot,
  # so the hint gives it, and drops the advice that fits a slow boot.
  def test_a_timeout_on_head_alone_gives_the_time_base_took
    row = ->(seconds) { { "id" => "t01", "file" => "a_test.rb", "name" => "a_test.rb#timeout", "classification" => "candidate", "base" => { "status" => "pass", "seconds" => seconds }, "head" => { "status" => "timeout" } } }
    run = { "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "rails_app" => true, "env_not_passed" => %w[DATABASE_URL] }
    text = ->(seconds) { JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge("tests" => [row.(seconds)]))) }

    assert_includes text.(2.1), "  t01 reported a_test.rb#timeout a_test.rb\n    hint: base passed in 2.1s; head did not finish in 10s, so head may loop or wait forever\n"
    assert_includes text.(7.4), "    hint: head timed out after 10s, and base passed in 7.4s; jitcatch did not pass DATABASE_URL"
  end

  # A name --env passed but the shell did not set reached the child as
  # nothing, which a longer timeout does not fix either, and the reader
  # chose that name, so the hint names it first.
  def test_a_timed_out_row_names_an_unset_env_name_before_one_jitcatch_did_not_pass
    row = { "id" => "t01", "file" => "a_test.rb", "name" => "a_test.rb#timeout", "classification" => "candidate", "base" => { "status" => "pass" }, "head" => { "status" => "timeout" } }
    hint = ->(doc) { JitCatch::Render.run_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "tests" => [row] }.merge(doc))).lines.grep(/hint:/).first }

    assert_equal "    hint: head timed out after 10s; --env QUINT passed nothing, because QUINT is not set, so set it if the file needs it, then raise --timeout if it needs longer\n",
      hint.("env" => %w[QUINT], "env_unset" => %w[QUINT])
    assert_equal "    hint: head timed out after 10s; --env QUINT --env SERVICE_URL passed nothing, because QUINT SERVICE_URL are not set, so set them if the file needs them; " \
                 "jitcatch did not pass HTTPS_PROXY, so add --env HTTPS_PROXY if the file needs it, then raise --timeout if it needs longer\n",
      hint.("env" => %w[QUINT SERVICE_URL], "env_unset" => %w[QUINT SERVICE_URL], "env_not_passed" => %w[HTTPS_PROXY])
  end

  # The rerun line runs in the reader's shell, so it names the variables the
  # run passed, and no value: a DATABASE_URL can hold a password, and a
  # report gets pasted where others read it.
  def test_a_rerun_line_names_the_env_it_reads_from_the_shell_and_no_value
    row = { "id" => "t01", "file" => "a_test.rb", "name" => "A#test_a", "classification" => "candidate", "rerun" => "ruby -Ilib -I. a_test.rb -n A#test_a",
            "base" => { "status" => "pass" }, "head" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1" } }
    rerun = ->(doc) { JitCatch::Render.assess_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "tests" => [row] }.merge(doc))).lines.drop_while { |line| !line.include?("rerun:") } }

    assert_equal ["    rerun: ruby -Ilib -I. a_test.rb -n A#test_a\n"], rerun.({})
    assert_equal ["    rerun: ruby -Ilib -I. a_test.rb -n A#test_a\n", "    rerun env: reads DATABASE_URL from your shell, as jitcatch run did\n"],
      rerun.("env" => %w[DATABASE_URL], "env_unset" => [])
    assert_equal ["    rerun: ruby -Ilib -I. a_test.rb -n A#test_a\n", "    rerun env: reads DATABASE_URL QUINT from your shell, as jitcatch run did; QUINT was not set for the run\n"],
      rerun.("env" => %w[DATABASE_URL QUINT], "env_unset" => %w[QUINT])
  end

  # The first line of a run that tested nothing names only what happened,
  # so a gem with no database does not read as one that lacked it.
  def test_an_untested_run_names_only_the_causes_its_rows_show
    timed_out = { "id" => "t01", "file" => "a_test.rb", "name" => "a_test.rb#timeout", "classification" => "candidate", "base" => { "status" => "timeout" }, "head" => { "status" => "timeout" } }
    no_database = { "id" => "t02", "file" => "b_test.rb", "name" => "B#test_b", "classification" => "candidate", "base" => { "status" => "pass" }, "head" => { "status" => "error", "error_class" => "ActiveRecord::NoDatabaseError" } }
    first = ->(tests) { JitCatch::Render.run_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "tests" => tests })).lines.first }

    assert_equal "jitcatch: no row ran to a result on both sides (1 of 1 timed out), so this run cannot tell base from head\n", first.([timed_out])
    assert_equal "jitcatch: no row ran to a result on both sides (1 of 1 found no database), so this run cannot tell base from head\n", first.([no_database])
    assert_equal "jitcatch: no row ran to a result on both sides (2 of 2 timed out or found no database), so this run cannot tell base from head\n", first.([timed_out, no_database])
    base_timed_out = timed_out.merge("classification" => "fail_on_base", "head" => { "status" => "pass" })
    base_no_database = no_database.merge("classification" => "fail_on_base", "base" => no_database["head"], "head" => { "status" => "pass" })
    assert_equal "jitcatch: no row ran to a result on both sides (2 of 2 timed out or found no database), so this run cannot tell base from head\n", first.([base_no_database, base_timed_out])
  end

  # A database that db:create made and nothing filled checked nothing, so
  # the run says which step loads the schema, naming the numbered
  # databases but never the URL, which can hold a password.
  def test_an_untested_run_whose_rows_found_no_table_says_to_load_the_schema
    no_table = { "status" => "error", "error_class" => "ActiveRecord::StatementInvalid", "message" => "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist" }
    row = { "id" => "t01", "file" => "loan_spec.rb", "name" => "Loan opens", "classification" => "fail_on_base", "base" => no_table, "head" => no_table }
    text = ->(extra) { JitCatch::Render.run_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "tests" => [row] }.merge(extra))).lines.first(2) }

    assert_equal [
      "jitcatch: no row ran to a result on both sides (1 of 1 found no table), so this run cannot tell base from head\n",
      "jitcatch: load the schema into app_test_1 and app_test_2: run `RAILS_ENV=test bin/rails db:prepare` (or `db:schema:load`) with DATABASE_URL naming each, then run jitcatch again\n"
    ], text.("numbered_databases" => %w[app_test_1 app_test_2])
    assert_equal [
      "jitcatch: no row ran to a result on both sides (1 of 1 found no table), so this run cannot tell base from head\n",
      "jitcatch: load the schema into each side's test database: run `RAILS_ENV=test bin/rails db:prepare` (or `db:schema:load`) for each database the checkouts use, or call `ActiveRecord::Migration.maintain_test_schema!` in the test helper, then run jitcatch again\n"
    ], text.({})
    timed_out = row.merge("id" => "t02", "base" => { "status" => "timeout" }, "head" => { "status" => "timeout" })
    assert_equal "jitcatch run\n", JitCatch::Render.run_text(JitCatch::Assessor.apply({ "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "tests" => [timed_out] })).lines[1]
  end

  # Rows the database hid beside rows that ran read like a run that
  # checked them all, unless the text says so, and a fail_on_base row
  # whose base found no table says which database lacks the schema.
  def test_rows_that_found_no_table_beside_rows_that_ran_get_a_warning_and_a_hint
    no_table = { "status" => "error", "error_class" => "ActiveRecord::StatementInvalid", "message" => "PG::UndefinedTable: ERROR:  relation \"loans\" does not exist" }
    hidden = ->(id) { { "id" => id, "file" => "loan_spec.rb", "name" => "Loan #{id}", "classification" => "fail_on_base", "base" => no_table, "head" => no_table } }
    wrong = { "id" => "t07", "file" => "notify_spec.rb", "name" => "Notify args", "classification" => "fail_on_base",
              "base" => { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1" }, "head" => { "status" => "pass" } }
    passing = wrong.merge("classification" => "no_signal", "base" => { "status" => "pass" })
    run = { "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 10, "numbered_databases" => %w[app_test_1 app_test_2] }
    text = ->(tests) { JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge("tests" => tests))) }
    hidden_rows = (1..6).map { |n| hidden.("t0#{n}") }

    mixed = text.(hidden_rows + [wrong])
    assert_equal "jitcatch: no row compared base with head (6 of 7 found no table, and 1 failed on base), so this run cannot tell base from head\n", mixed.lines.first
    assert_includes mixed, "  t01 fail_on_base Loan t01 loan_spec.rb\n    base: error ActiveRecord::StatementInvalid PG::UndefinedTable: ERROR:  relation \"loans\" does not exist\n" \
                           "    hint: base found no table, so this row checked nothing; load base's schema into app_test_1\n"
    ran = text.(hidden_rows + [passing])
    assert_equal "jitcatch run\n", ran.lines.first
    assert_includes ran, "head h\nwarning: 6 of 7 rows found no table on a side, so they checked nothing; load the schema into app_test_1 and app_test_2: " \
                         "run `RAILS_ENV=test bin/rails db:prepare` (or `db:schema:load`) with DATABASE_URL naming each, then run jitcatch again\nreruns 0\n"
    refute_includes text.([passing]), "warning:"
    unnumbered = JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge("numbered_databases" => [], "tests" => [hidden.("t01"), passing])))
    assert_includes unnumbered, "    hint: base found no table, so this row checked nothing; load base's schema into its test database\n"
    assert_includes unnumbered, "warning: 1 of 2 rows found no table on a side, so it checked nothing; load the schema into each side's test database: "
  end

  # A Rails app rescues the error behind a 500 and writes it to its log,
  # so the failure message alone never names the cause.
  def test_a_reported_row_whose_head_answered_500_names_the_test_log
    row = ->(message) {
      { "id" => "t01", "file" => "things_spec.rb", "name" => "Things refresh", "classification" => "candidate", "mentions" => [],
        "base" => { "status" => "pass" }, "head" => { "status" => "fail", "error_class" => "RSpec::Expectations::ExpectationNotMetError", "message" => message } }
    }
    run = { "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 0, "timeout_s" => 60, "rails_app" => true, "methods" => [], "constants" => [] }
    hints = ->(message, extra = {}) { JitCatch::Render.run_text(JitCatch::Assessor.apply(run.merge(extra).merge("tests" => [row.(message)]))).lines.grep(/hint:/) }
    hint = "    hint: head answered 500, and a Rails app writes the error behind it to log/test.log; run the row's rerun line and read that log\n"

    assert_equal [hint], hints.("\nexpected: [201, {\"id\" => \"1\"}]\n     got: [500, nil]\n")
    assert_equal [hint], hints.("expected the response to have status code :created (201) but it was :internal_server_error (500)")
    assert_equal [hint], hints.("Expected response to be a <201: created>, but was a <500: Internal Server Error>")
    assert_equal [], hints.("expected: 500\n     got: 450")
    assert_equal [], hints.("\nexpected: [201, nil]\n     got: [500, nil]\n", "rails_app" => false)
  end

  def test_context_text_lists_dependencies_only_when_one_changed
    doc = {
      "version" => "0.1.0", "base" => "b", "head" => "h", "existing_tests_via" => "grep",
      "intent" => [], "files" => [], "constants" => [], "methods" => [], "entrypoints" => [], "parse_errors" => [],
      "dependencies" => [{ "gem" => "rack", "old" => "3.0.0", "new" => nil }]
    }
    assert_includes JitCatch::Render.context_text(doc), "  (none)
dependencies:
  rack 3.0.0 -> (none)
constants: (none)
"
    assert_includes JitCatch::Render.context_text(doc.merge("dependencies" => [])), "  (none)
constants: (none)
"
    assert_includes JitCatch::Render.context_text(doc.reject { |key, _| key == "dependencies" }), "  (none)
constants: (none)
"
  end

  def test_context_text_names_the_file_a_moved_method_came_from
    method = {
      "id" => "m01", "change" => "moved", "name" => "A#b", "file" => "test/a.rb", "start_line" => 3, "end_line" => 5,
      "signature" => "()", "visibility" => "public", "moved_from" => "lib/a.rb", "callsites" => [], "reachable_from" => [],
      "existing_tests" => [], "entry_point_tests" => []
    }
    doc = {
      "version" => "0.1.0", "base" => "b", "head" => "h", "existing_tests_via" => "grep",
      "intent" => [], "files" => [], "constants" => [], "methods" => [method], "entrypoints" => [], "parse_errors" => []
    }
    assert_includes JitCatch::Render.context_text(doc),
      "  [m01] moved A#b test/a.rb:3-5 signature=() visibility=public moved_from=lib/a.rb\n"
  end

  def test_context_text_starts_with_the_revisions_and_any_warning
    doc = {
      "version" => "0.1.0", "base" => "b", "head" => "h", "existing_tests_via" => "grep", "warnings" => ["w1"],
      "intent" => [], "files" => [], "constants" => [], "methods" => [], "entrypoints" => [], "parse_errors" => []
    }
    assert_equal <<~TEXT, JitCatch::Render.context_text(doc).lines.first(7).join
      jitcatch context
      version 0.1.0
      base b
      head h
      warning: w1
      existing_tests grep
      intent: (none)
    TEXT
  end

  def test_context_text_reports_parse_errors_and_no_entry_points
    doc = {
      "version" => "0.1.0", "base" => "b", "head" => "h", "existing_tests_via" => "grep",
      "intent" => [], "files" => [], "constants" => [], "methods" => [], "entrypoints" => [],
      "parse_errors" => [{ "ref" => "h", "file" => "lib/bad.rb", "message" => "L1: unexpected end-of-input" }]
    }
    text = JitCatch::Render.context_text(doc)
    assert_includes text, "intent: (none)\nfiles:\n  (none)\n"
    assert text.end_with?("entrypoints: (none)\nparse_errors:\n  h lib/bad.rb L1: unexpected end-of-input\n"), text
  end

  def test_an_rspec_eq_failure_shows_expected_and_got_or_the_entries_that_differ
    assert_equal ["expected: 3", "got: 4"], JitCatch::Render.message_lines({ "message" => "\nexpected: 3\n     got: 4\n\n(compared using ==)\n" })
    long = "x" * 90
    message = "expected: {a: 2, b: \"#{long}\"}\n     got: {a: 1, b: \"#{long}\"}\n"
    assert_equal ["hash keys differ: a", "-a => 2", "+a => 1"], JitCatch::Render.message_lines({ "message" => message })
    edge = "y" * 100
    assert_equal ["expected: #{edge}", "got: #{edge}"], JitCatch::Render.message_lines({ "message" => "expected: #{edge}\ngot: #{edge}" })
    assert_equal ["got: 4"], JitCatch::Render.message_lines({ "message" => "got: 4\nexpected: 3" })
    assert_equal ["expected: 3"], JitCatch::Render.message_lines({ "message" => "expected: 3\nboom" })
  end

  # The messages rspec-expectations 3.13 and rspec-mocks 3.13 print.
  def test_an_rspec_be_equal_or_argument_failure_shows_the_got_line
    assert_equal ["expected true", "got false"], JitCatch::Render.message_lines({ "message" => "expected true\n     got false" })
    identity = "expected #<String:504> => \"100\"\n     got #<String:512> => \"120\"\n\nCompared using equal?, which compares object identity,\nbut expected and actual are not the same object."
    assert_equal ["expected #<String:504> => \"100\"", "got #<String:512> => \"120\""], JitCatch::Render.message_lines({ "message" => identity })
    arguments = "#<Klass (class)> received :call with unexpected arguments\n  expected: ({flag: true, id: \"x\"}) (options hash)\n       got: ({id: \"x\"}) (keyword arguments)\nDiff:\n@@ -1 +1 @@\n-[{flag: true, id: \"x\"}]\n+[{id: \"x\"}]"
    assert_equal ["#<Klass (class)> received :call with unexpected arguments", "expected: ({flag: true, id: \"x\"}) (options hash)", "got: ({id: \"x\"}) (keyword arguments)"],
      JitCatch::Render.message_lines({ "message" => arguments })
    assert_equal ["expected true"], JitCatch::Render.message_lines({ "message" => "expected true\nboom" })
    assert_equal ["received :call"], JitCatch::Render.message_lines({ "message" => "received :call\nexpected: (1)\nboom" })
  end

  def test_a_fail_on_base_row_shows_the_got_line_under_base
    test = { "disposition" => "fail_on_base", "base" => { "status" => "fail", "error_class" => "E", "message" => "#<K (class)> received :call with unexpected arguments\n  expected: (1)\n       got: (2)" } }

    assert_equal ["    base: fail E #<K (class)> received :call with unexpected arguments", "      expected: (1)", "      got: (2)"],
      JitCatch::Render.base_failure_lines(test, {})
  end

  def test_an_assert_raises_failure_shows_the_class_and_message_that_came
    message = "[KeyError] exception expected, not\nClass: <ArgumentError>\nMessage: <\"wrapped k\">"

    assert_equal ["[KeyError] exception expected, not", "Class: <ArgumentError>", "Message: <\"wrapped k\">"],
      JitCatch::Render.message_lines({ "message" => message })
    assert_equal ["[KeyError] exception expected, not"], JitCatch::Render.message_lines({ "message" => "[KeyError] exception expected, not\nboom\nMessage: <1>" })
    assert_equal ["Keys."], JitCatch::Render.message_lines({ "message" => "Keys.\nClass: <ArgumentError>\nMessage: <1>" })
  end

  def test_an_error_row_names_its_cause
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h",
      "tests" => [
        { "id" => "t01", "name" => "A errors", "classification" => "candidate", "base" => { "status" => "pass" },
          "head" => { "status" => "error", "error_class" => "W", "message" => "outer", "cause" => { "error_class" => "KeyError", "message" => "inner k\nmore" } } }
      ]
    })

    assert_equal ["  c01 A errors base=pass head=error - error:W,report", "    outer", "    cause: KeyError: inner k"],
      JitCatch::Render.assess_text(doc).split("assess:\n").last.lines(chomp: true)
  end

  def test_assess_prints_the_warnings_of_the_run
    doc = { "version" => "0.1.0", "base" => "b", "head" => "h", "warnings" => ["base is not an ancestor of head"], "tests" => [],
            "counts" => { "generated" => 0, "no_signal" => 0, "fail_on_base" => 0, "candidates" => 0, "flaky" => 0, "discarded" => 0, "reported" => 0 } }

    assert JitCatch::Render.assess_text(doc).start_with?("jitcatch assess\nversion 0.1.0\nbase b\nhead h\nwarning: base is not an ancestor of head\ncounts ")
    assert_equal ["base is not an ancestor of head"], JitCatch::Render.assess_json(doc)["warnings"]
  end

  def test_a_rerun_line_shows_the_first_message_line_that_moved
    test = { "head" => { "message" => "Expected: 0\n  Actual: 1" }, "reruns" => [{ "status" => "fail", "error_class" => "Minitest::Assertion", "message_first_line" => "Expected: 0", "message" => "Expected: 0\n  Actual: 2" }] }

    assert_equal ["    rerun 1: fail Minitest::Assertion Actual: 2"], JitCatch::Render.rerun_lines(test)
  end

  def test_a_rerun_line_says_when_only_the_message_moved_and_cuts_a_long_line
    long = "x" * 500
    test = { "head" => { "status" => "fail", "error_class" => "E", "message" => "Expected: 0\n  Actual: 1" },
             "reruns" => [{ "status" => "fail", "error_class" => "E", "message_first_line" => "Expected: 0", "message" => "Expected: 0\n  Actual: #{long}" },
                          { "status" => "error", "error_class" => "F", "message_first_line" => "boom", "message" => "boom" }],
             "base_reruns" => [{ "status" => "fail", "error_class" => "E", "message_first_line" => "Expected: 0", "message" => "Expected: 0\n  Actual: 2" }] }

    lines = JitCatch::Render.rerun_lines(test)

    assert_match(/\A    rerun 1: fail E \(same outcome, message differs\) Actual: x+\.\.\. \(\+\d+ characters; the whole message is in --json\) \.\.\.x+\z/, lines[0])
    assert_operator lines[0].length, :<, 400
    assert_equal ["    rerun 2: error F boom", "    base rerun 1: fail E Expected: 0"], lines.drop(1)
  end
end
