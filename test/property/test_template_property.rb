# frozen_string_literal: true

require_relative "property_helper"

class TestTemplateProperty < Minitest::Test
  # A template's text, its comments, and its tags may each span lines;
  # every call keeps the line it has in the template, and only a `<%=`
  # tag's value is printed.
  def test_a_call_keeps_its_template_line
    Hegel.test do |tc|
      pieces = tc.draw(arrays(one_of(
        from_regex('\A[a-z <>/]{0,6}(\n[a-z <>/]{0,6}){0,2}\z').map { |text| [text, nil] },
        from_regex('\A[a-z]{1,4}\z').map { |name| ["<%= #{name}_v %>", [name, true]] },
        from_regex('\A[a-z]{1,4}\z').map { |name| ["<%\n  #{name}_v\n%>", [name, false]] },
        from_regex('\A[a-z ]{0,6}(\n[a-z ]{0,6}){0,2}\z').map { |text| ["<%# #{text} %>", nil] }
      ), max_size: 8))
      template = +""
      expected = []
      pieces.each do |text, call|
        line = template.count("\n") + 1
        line += 1 if text.start_with?("<%\n")
        expected << ["#{call[0]}_v", line, call[1]] if call
        template << text
      end
      found = []
      pending = [Prism.parse(JitCatch::Template.as_ruby(template)).value]
      while (node = pending.pop)
        if node.is_a?(Prism::CallNode) && node.name.to_s.end_with?("_v")
          found << [node.name.to_s, node.location.start_line, false]
        elsif node.is_a?(Prism::CallNode) && node.name == JitCatch::Template::OUTPUT
          inner = node.arguments.arguments.first
          found << [inner.name.to_s, inner.location.start_line, true]
          next
        end
        pending.concat(node.compact_child_nodes)
      end
      assert_equal expected.sort, found.sort
    end
  end
end
