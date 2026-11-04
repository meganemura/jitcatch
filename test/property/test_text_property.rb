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

  def test_mask_temp_names_is_idempotent_and_forgets_the_random_name
    Hegel.test do |tc|
      root = tc.draw(sampled_from(["/tmp", "/var/folders/x/T", "/private/tmp/"]))
      prefix = tc.draw(from_regex("([a-z]{0,5}[ \"])?"))
      suffix = tc.draw(from_regex("(/[a-z_.0-9]{1,6}){0,2}( [a-z]{0,4})?"))
      first, second = tc.draw(arrays(from_regex("[a-z]{0,5}[0-9]{8}-[0-9]{1,5}-[a-z0-9]{1,7}"), min_size: 2, max_size: 2))
      dir = root.chomp("/")
      one = "#{prefix}#{dir}/#{first}#{suffix}"
      two = "#{prefix}#{dir}/#{second}#{suffix}"
      masked = JitCatch::Text.mask_temp_names(one, root)
      assert_equal masked, JitCatch::Text.mask_temp_names(two, root)
      assert_equal masked, JitCatch::Text.mask_temp_names(masked, root)
    end
  end

  def test_mask_addresses_forgets_which_address_an_object_had
    Hegel.test do |tc|
      prefix = tc.draw(from_regex("[A-Za-z: ]{0,8}#<[A-Z][a-z]{0,5}:"))
      first, second = tc.draw(arrays(from_regex("0x[0-9a-f]{6,16}"), min_size: 2, max_size: 2))
      masked = JitCatch::Text.mask_addresses("#{prefix}#{first}>")
      assert_equal masked, JitCatch::Text.mask_addresses("#{prefix}#{second}>")
      assert_equal masked, JitCatch::Text.mask_addresses(masked)
    end
  end

  # The removed elements are named by their index in the old Array, and what
  # the old Array keeps without them is a longest common subsequence.
  def test_element_changes_keep_a_longest_common_subsequence
    Hegel.test do |tc|
      old_items, new_items = tc.draw(arrays(arrays(integers(min_value: 0, max_value: 3), max_size: 7), min_size: 2, max_size: 2))
      changes = JitCatch::Render.element_changes(old_items, new_items)
      removed = changes.select { |_, old_item, _| old_item }
      added = changes.select { |_, _, new_item| new_item }
      removed.each { |index, old_item, _| assert_equal old_items[index], old_item }
      added.each { |index, old_item, new_item| assert_equal new_items[index], new_item unless old_item }
      kept = old_items.reject.with_index { |_, index| removed.any? { |at, _, _| at == index } }
      common = common_length(old_items, new_items)
      assert_equal common, kept.size
      assert_equal new_items.size - common, added.size
      assert subsequence?(kept, new_items), "#{kept} is not in #{new_items}"
    end
  end

  def test_dedent_undoes_indent
    Hegel.test do |tc|
      lines = tc.draw(arrays(from_regex("[a-z#][a-z ]{0,5}"), min_size: 1, max_size: 6))
      spaces = tc.draw(integers(min_value: 0, max_value: 8))
      assert_equal lines.join("\n"), JitCatch::Text.dedent(JitCatch::Text.indent(lines.join("\n"), spaces))
    end
  end

  private

  def common_length(left, right)
    row = Array.new(right.size + 1, 0)
    left.each do |item|
      previous = 0
      right.each_with_index do |other, j|
        current = row[j + 1]
        row[j + 1] = item == other ? previous + 1 : [row[j + 1], row[j]].max
        previous = current
      end
    end
    row.last
  end

  def subsequence?(items, within)
    at = 0
    items.all? do |item|
      found = within.index.with_index { |other, index| index >= at && other == item }
      at = found + 1 if found
      found
    end
  end
end
