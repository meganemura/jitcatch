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

  def test_indent_pads_each_line_and_names_empty_text
    assert_equal "  (none)", Text.indent(nil, 2)
    assert_equal "   (none)", Text.indent("", 3)
    assert_equal "  a\n  \n  b", Text.indent("a\n\nb", 2)
  end
end
