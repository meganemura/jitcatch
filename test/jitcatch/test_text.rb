# frozen_string_literal: true

require_relative "../test_helper"

class TestText < Minitest::Test
  Text = JitCatch::Text

  def test_cap_lines_keeps_up_to_the_limit_and_cuts_the_middle_past_it
    assert_nil Text.cap_lines(nil)
    assert_equal "a\nb", Text.cap_lines("a\nb\n")
    forty = (1..40).map(&:to_s)
    assert_equal forty.join("\n"), Text.cap_lines(forty.join("\n"))
    forty_one = (1..41).map(&:to_s)
    assert_equal [*forty_one.first(32), "# ...", *forty_one.last(7)].join("\n"), Text.cap_lines(forty_one.join("\n"))
  end

  def test_dedent_removes_the_common_indent_and_keeps_blank_lines_empty
    assert_nil Text.dedent(nil)
    assert_equal "def a\n  1\n\nend", Text.dedent("    def a\n      1\n\n    end\n")
    assert_equal "\n", Text.dedent("\n\n")
    assert_equal "x\n\ty", Text.dedent("\tx\n\t\ty")
  end

  def test_mask_temp_names_replaces_the_name_under_the_temp_directory
    assert_equal "replay of {tmp}/trace_0.itf.json failed",
      Text.mask_temp_names("replay of /tmp/quint20261103-77-abc/trace_0.itf.json failed", "/tmp")
    assert_equal "{tmp} and {tmp}/x", Text.mask_temp_names("/var/t/d1 and /var/t/d2/x", "/var/t/")
    assert_equal "/tmpfoo/x and /tmp", Text.mask_temp_names("/tmpfoo/x and /tmp", "/tmp")
    assert_equal "/other/quint1/x", Text.mask_temp_names("/other/quint1/x", "/tmp")
    assert_equal "/home/tmp/x", Text.mask_temp_names("/home/tmp/x", "/tmp")
    assert_equal "/tmp/a/x", Text.mask_temp_names("/tmp/a/x", "/")
    assert_equal "/tmp/a/x", Text.mask_temp_names("/tmp/a/x", nil)
  end

  def test_mask_times_replaces_a_time_of_day_and_keeps_a_date
    record = %(#<Loan id: 1, created_at: "2026-11-04 19:02:03.212197000 +0000", updated_at: "2026-11-04 19:02:03.212197000 +0000">)
    assert_equal %(#<Loan id: 1, created_at: "{time}", updated_at: "{time}">), Text.mask_times(record)
    assert_equal "at {time} and {time} and {time}", Text.mask_times("at 2026-11-04 19:02:03 UTC and 2026-11-04T19:02:03.5Z and 2026-11-04 19:02:03 +09:00")
    assert_equal "due 2026-11-04, 12:30", Text.mask_times("due 2026-11-04, 12:30")
  end

  def test_indent_pads_each_line_and_names_empty_text
    assert_equal "  (none)", Text.indent(nil, 2)
    assert_equal "   (none)", Text.indent("", 3)
    assert_equal "  a\n  \n  b", Text.indent("a\n\nb", 2)
  end
end
