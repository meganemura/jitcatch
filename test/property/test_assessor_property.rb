# frozen_string_literal: true

require_relative "property_helper"

class TestAssessorProperty < Minitest::Test
  CLASSIFICATIONS = %w[candidate no_signal fail_on_base flaky].freeze
  HEADS = [
    { "status" => "fail", "error_class" => "Minitest::Assertion", "message" => "Expected: 1\n  Actual: 2" },
    { "status" => "timeout", "error_class" => "Timeout", "message" => "timeout" },
    { "status" => "error", "error_class" => "LoadError", "message" => "cannot load such file -- x" },
    { "status" => "error", "error_class" => "NoMethodError", "message" => "undefined method 'gone' for nil" },
    { "status" => "error", "error_class" => "NoMethodError", "message" => "undefined method 'resize' for nil" },
    { "status" => "error", "error_class" => "ArgumentError", "message" => "wrong number of arguments (given 1, expected 2)" },
    { "status" => "error", "error_class" => "ArgumentError", "message" => "qty must be > 0" }
  ].freeze
  METHODS = [
    { "id" => "m01", "change" => "removed", "signature" => "removed", "bare_name" => "gone", "name" => "A#gone",
      "file" => "lib/a.rb", "start_line" => 1, "end_line" => 3, "reachable_from" => [] },
    { "id" => "m02", "change" => "modified", "signature" => "changed", "bare_name" => "resize", "name" => "A#resize",
      "file" => "lib/a.rb", "start_line" => 10, "end_line" => 12, "reachable_from" => ["A#render"] }
  ].freeze

  def draw_doc(tc)
    size = tc.draw(integers(min_value: 0, max_value: 12))
    tests = Array.new(size) do |index|
      head = HEADS[tc.draw(integers(min_value: 0, max_value: HEADS.size - 1))]
      mentions = tc.draw(subsequences(%w[gone resize render]))
      {
        "id" => format("t%02d", index + 1),
        "name" => "T#test_#{index}",
        "mentions" => mentions,
        "classification" => tc.draw(sampled_from(CLASSIFICATIONS)),
        "base" => { "status" => "pass" },
        "head" => head.merge("backtrace" => [])
      }
    end
    { "methods" => METHODS, "constants" => [], "tests" => tc.draw(permutations(tests)) }
  end

  def test_counts_partition_the_rows
    Hegel.test do |tc|
      out = JitCatch::Assessor.apply(draw_doc(tc))
      counts = out["counts"]
      assert_equal out["tests"].size, counts.values_at("no_signal", "fail_on_base", "candidates", "flaky").sum
      assert_equal counts["candidates"], counts["discarded"] + counts["reported"]
      out["tests"].each do |test|
        candidate = test["classification"] == "candidate"
        assert_equal candidate, %w[discarded reported].include?(test["disposition"])
        assert_equal candidate, !test["candidate_id"].nil?
        assert_equal 1, test["tags"].count { |tag| tag == "report" || tag.start_with?("discard:") } if candidate
        assert_equal test["tags"].uniq.sort, test["tags"]
      end
    end
  end

  def test_candidate_ids_number_candidates_in_test_id_order
    Hegel.test do |tc|
      rows = JitCatch::Assessor.apply(draw_doc(tc))["tests"].select { |test| test["candidate_id"] }
      assert_equal (1..rows.size).map { |n| format("c%02d", n) }, rows.sort_by { |test| test["id"] }.map { |test| test["candidate_id"] }
    end
  end

  def test_applying_twice_or_in_another_order_changes_nothing
    Hegel.test do |tc|
      doc = draw_doc(tc)
      once = JitCatch::Assessor.apply(doc)
      assert_equal once, JitCatch::Assessor.apply(once)
      shuffled = JitCatch::Assessor.apply(doc.merge("tests" => tc.draw(permutations(doc["tests"]))))
      assert_equal once["counts"], shuffled["counts"]
      assert_equal once["tests"].sort_by { |test| test["id"] }, shuffled["tests"].sort_by { |test| test["id"] }
    end
  end

  def test_a_head_timeout_or_load_error_is_always_discarded
    Hegel.test do |tc|
      out = JitCatch::Assessor.apply(draw_doc(tc))
      out["tests"].each do |test|
        next unless test["classification"] == "candidate"

        case test["head"]["error_class"]
        when "Timeout" then assert_includes test["tags"], "discard:timeout"
        when "LoadError" then assert_includes test["tags"], "discard:load_error"
        when "Minitest::Assertion" then assert_equal "reported", test["disposition"]
        end
      end
    end
  end

  def test_a_test_mentions_a_constructor_as_new_on_the_last_name_segment
    Hegel.test do |tc|
      segments = tc.draw(arrays(sampled_from(%w[Shop Cart Mismatch]), min_size: 1, max_size: 3))
      sep = tc.draw(sampled_from(%w[# .]))
      bare = tc.draw(sampled_from(%w[initialize new total]))
      constructor = { "#" => "initialize", "." => "new" }.fetch(sep) == bare
      expected = constructor ? "#{segments.last}.new" : bare
      assert_equal expected, JitCatch::Assessor.mention_of("#{segments.join("::")}#{sep}#{bare}")
    end
  end

  # A broken call is discarded only from the candidate file, and the
  # verdict does not depend on whether assert_raises or raise_error caught
  # the error.
  def test_a_broken_call_is_discarded_only_from_the_test_and_however_it_was_caught
    Hegel.test do |tc|
      call = { "file" => tc.draw(sampled_from(%w[.jitcatch/a_test.rb lib/a.rb lib/b.rb])), "line" => tc.draw(integers(min_value: 1, max_value: 30)) }
      arity = tc.draw(booleans)
      message = arity ? "wrong number of arguments (given 1, expected 2)" : "undefined method 'gone' for an instance of B"
      error_class = arity ? "ArgumentError" : "NoMethodError"
      # Ruby puts the callee's own line first for an arity error.
      raised = arity ? [{ "file" => "lib/a.rb", "line" => 10 }, call] : [call]
      raised << { "file" => ".jitcatch/a_test.rb", "line" => 4 }
      at = { "file" => ".jitcatch/a_test.rb", "line" => 4 }
      head = case tc.draw(sampled_from(%w[bare minitest rspec]))
      when "bare" then { "status" => "error", "error_class" => error_class, "message" => message, "backtrace" => raised }
      when "minitest"
        { "status" => "fail", "error_class" => "Minitest::Assertion", "backtrace" => [at, *raised],
          "message" => "[KeyError] exception expected, not\nClass: <#{error_class}>\nMessage: <#{message.inspect}>" }
      else
        { "status" => "fail", "error_class" => "RSpec::Expectations::ExpectationNotMetError", "backtrace" => [at, *raised],
          "message" => "expected KeyError, got #<#{error_class}: #{message}>" }
      end
      test = { "id" => "t01", "name" => "T#test_a", "mentions" => [], "classification" => "candidate", "base" => { "status" => "pass" }, "head" => head }
      row = JitCatch::Assessor.apply({ "methods" => METHODS, "constants" => [], "tests" => [test] })["tests"].fetch(0)

      from_test = call["file"].start_with?(".jitcatch/")
      assert_equal from_test ? "discarded" : "reported", row["disposition"], row["tags"].inspect
      changed = call["file"] == "lib/a.rb" && (10..12).cover?(call["line"])
      expected = from_test ? [] : ["caller:#{changed ? "changed" : "unchanged"}:#{call["file"]}:#{call["line"]}"]
      assert_equal expected, row["tags"].grep(/\Acaller:/)
    end
  end
end
