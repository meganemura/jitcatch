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

  def test_run_text_names_omitted_files_and_an_empty_run
    doc = JitCatch::Assessor.apply({
      "version" => "0.1.0", "base" => "b", "head" => "h", "reruns" => 2, "timeout_s" => 10,
      "test_files_omitted" => 3, "tests" => []
    })
    assert_equal <<~TEXT, JitCatch::Render.run_text(doc)
      jitcatch run
      version 0.1.0
      base b
      head h
      reruns 2
      timeout_s 10
      test_files_omitted 3
      tests:
        (none)
      counts generated=0 no_signal=0 fail_on_base=0 candidates=0 flaky=0 discarded=0 reported=0
      assess:
        (none)
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
end
