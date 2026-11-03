# frozen_string_literal: true

require_relative "property_helper"

class TestTextProperty < Minitest::Test
  def test_cap_lines_keeps_forty_lines_and_cuts_longer_text_to_forty
    Hegel.test do |tc|
      text = tc.draw(arrays(text(max_size: 3, alphabet: "ab "), max_size: 60)).join("\n")
      lines = text.chomp.split("\n", -1)
      capped = JitCatch::Text.cap_lines(text)
      if lines.size <= 40
        assert_equal text.chomp, capped
      else
        assert_equal [*lines.first(32), "# ...", *lines.last(7)], capped.split("\n", -1)
      end
    end
  end

  def test_dedent_undoes_indent
    Hegel.test do |tc|
      lines = tc.draw(arrays(from_regex("[a-z#][a-z ]{0,5}"), min_size: 1, max_size: 6))
      spaces = tc.draw(integers(min_value: 0, max_value: 8))
      assert_equal lines.join("\n"), JitCatch::Text.dedent(JitCatch::Text.indent(lines.join("\n"), spaces))
    end
  end
end
