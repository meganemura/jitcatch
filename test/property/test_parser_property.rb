# frozen_string_literal: true

require_relative "property_helper"

class TestParserProperty < Minitest::Test
  def draw_hunk(tc)
    %w[old_start old_count new_start new_count].to_h { |key| [key, tc.draw(integers(min_value: 0, max_value: 60))] }
  end

  def header(hunk, tc)
    side = lambda do |start, count|
      count == 1 && tc.draw(booleans) ? start.to_s : "#{start},#{count}"
    end
    "@@ -#{side.call(hunk["old_start"], hunk["old_count"])} +#{side.call(hunk["new_start"], hunk["new_count"])} @@ def x"
  end

  def test_diff_hunks_round_trip
    Hegel.test do |tc|
      hunks = tc.draw(arrays(composite { |inner| draw_hunk(inner) }, max_size: 5))
      text = ["diff --git a/x.rb b/x.rb", "--- a/x.rb", "+++ b/x.rb", *hunks.map { |hunk| header(hunk, tc) }].join("\n")
      assert_equal [{ "old_path" => "x.rb", "new_path" => "x.rb", "hunks" => hunks }], JitCatch::DiffParser.parse(text)
    end
  end

  def test_overlap_means_a_shared_line
    Hegel.test do |tc|
      hunks = tc.draw(arrays(composite { |inner| draw_hunk(inner) }, max_size: 4))
      first = tc.draw(integers(min_value: 0, max_value: 60))
      last = tc.draw(integers(min_value: first, max_value: 70))
      side = tc.draw(sampled_from(%w[old new]))
      shared = hunks.any? { |hunk|
        lines = hunk["#{side}_start"]...(hunk["#{side}_start"] + hunk["#{side}_count"])
        lines.any? { |line| (first..last).cover?(line) }
      }
      assert_equal shared, JitCatch::DiffParser.overlaps?(first, last, hunks, side)
    end
  end

  def test_verbose_minitest_lines_round_trip
    Hegel.test do |tc|
      names = tc.draw(arrays(from_regex("[A-Z][a-z]{0,4}Test#test_[a-z_]{1,8}"), unique: true, max_size: 6))
      letters = names.to_h { |name| [name, tc.draw(sampled_from(%w[. F E S]))] }
      stdout = [
        "Run options: -v --seed 1", "", "# Running:", "",
        *letters.map { |name, letter| "#{name} = 0.00 s = #{letter}" },
        "", "#{names.size} runs, 0 assertions, 0 failures, 0 errors, 0 skips"
      ].join("\n")
      parsed = JitCatch::MinitestParser.parse(stdout, "")
      status = { "." => "pass", "F" => "fail", "E" => "error", "S" => "skip" }
      assert_equal letters.transform_values { |letter| status.fetch(letter) }, parsed["tests"].transform_values { |result| result["status"] }
      assert_equal [true, nil], parsed.values_at("summary", "file_error")
    end
  end

  def test_split_qualified_reverses_qualify
    Hegel.test do |tc|
      qualifier = tc.draw(from_regex("([A-Z][a-z]{0,3}(::[A-Z][a-z]{0,3}){0,2})?"))
      bare = tc.draw(from_regex("[a-z_][a-z0-9_]{0,6}[?!]?"))
      singleton = tc.draw(booleans)
      qualified = JitCatch::SourceIndex.qualify(qualifier, bare, singleton)
      assert_equal [qualifier, singleton ? "." : "#", bare], JitCatch::SourceIndex.split_qualified(qualified)
    end
  end
end
