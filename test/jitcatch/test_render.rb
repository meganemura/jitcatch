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

    assert_equal ["#{long[0, 300]}... (+#{long.length - 300} more; the whole message is in --json)"], lines
    assert_equal ["x" * 300], JitCatch::Render.message_lines({ "message" => "x" * 300 })
    assert_equal ["Expected: 1", "Actual: #{"y" * 292}... (+1 more; the whole message is in --json)"],
      JitCatch::Render.message_lines({ "message" => "Expected: 1\n  Actual: #{"y" * 293}" })
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
  def test_run_text_prints_reruns_under_a_flaky_row_and_a_hint_under_a_timeout
    fail_line = { "status" => "fail", "error_class" => "Minitest::Assertion", "message_first_line" => "Expected: 1" }
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 2, "timeout_s" => 7, "tests" => [
        { "id" => "t01", "file" => "a_test.rb", "name" => "A#test_a", "classification" => "flaky",
          "base" => { "status" => "pass" }, "head" => fail_line, "reruns" => [fail_line, { "status" => "pass", "error_class" => nil, "message_first_line" => "" }] },
        { "id" => "t02", "file" => "b_test.rb", "name" => "b_test.rb#timeout", "classification" => "fail_on_base",
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
        t02 fail_on_base b_test.rb#timeout b_test.rb
          hint: base timed out after 7s; raise --timeout if the file needs longer
          hint: head timed out after 7s; raise --timeout if the file needs longer
        t03 no_signal C#test_c c_test.rb
        t04 fail_on_base D#test_d d_test.rb
          base: error NoMethodError undefined method 'coupon' for an instance of Cart
        t05 fail_on_base E#test_e e_test.rb
          base: fail Minitest::Assertion Expected: 1
            Actual: 2
      counts generated=5
    TEXT
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
end
