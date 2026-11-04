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

  def test_strings_and_comments_do_not_change_what_a_test_refers_to
    Hegel.test do |tc|
      code = ["cart = Shop::Cart.new", "cart.total += 1", "assert_equal 3, helper(:run)"]
      words = tc.draw(arrays(from_regex("[A-Za-z_:.# ]{0,20}", fullmatch: true), min_size: 1, max_size: 4))
      noise = words.flat_map { |word| ["note = '#{word}'", "# #{word}", "label = \"#{word}\#{1}\""] }
      body = noise.reduce(code) { |lines, line| lines.dup.insert(tc.draw(integers(min_value: 0, max_value: lines.size)), line) }
      source = "class T\n  def test_x\n#{body.map { |line| "    #{line}" }.join("\n")}\n  end\n\n  def helper(name) = Price.new\nend\n"
      plain = "class T\n  def test_x\n#{code.map { |line| "    #{line}" }.join("\n")}\n  end\n\n  def helper(name) = Price.new\nend\n"
      assert_equal JitCatch::SourceIndex.parse(plain, file: "t.rb").referenced_names("T#test_x"),
        JitCatch::SourceIndex.parse(source, file: "t.rb").referenced_names("T#test_x")
    end
  end

  def test_hash_key_symbols_do_not_change_what_a_test_refers_to
    Hegel.test do |tc|
      code = ["snap = cart.snapshot", "assert_equal 1, snap[:total]", "snap.fetch(:tax, 0)", "snap.dig(:a)", "snap.key?(:b)", "row = { a: total }"]
      keys = tc.draw(arrays(from_regex("[a-z_][a-z0-9_]{0,12}[?!]?", fullmatch: true), min_size: 1, max_size: 4))
      noise = keys.flat_map { |key|
        ["snap[:#{key}]", "snap[:#{key}] = 1", "snap.fetch(:#{key})", "snap.dig(:#{key}, :#{key})", "snap.key?(:#{key})", "row = { #{key}: 1, :#{key} => 2 }"]
      }
      body = noise.reduce(code) { |lines, line| lines.dup.insert(tc.draw(integers(min_value: 1, max_value: lines.size)), line) }
      source = "class T\n  def test_x\n#{body.map { |line| "    #{line}" }.join("\n")}\n  end\nend\n"
      plain = "class T\n  def test_x\n#{(code + ["snap[:a] = 1"]).map { |line| "    #{line}" }.join("\n")}\n  end\nend\n"
      assert_equal JitCatch::SourceIndex.parse(plain, file: "t.rb").referenced_names("T#test_x"),
        JitCatch::SourceIndex.parse(source, file: "t.rb").referenced_names("T#test_x")
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

  def test_blobs_read_back_as_written
    repo = Support::Repo.new
    git = JitCatch::GitRepo.new(repo.dir)
    Hegel.test do |tc|
      texts = tc.draw(arrays(text(max_size: 30), max_size: 4))
      paths = texts.each_with_index.map do |body, index|
        File.join(repo.dir, "blob#{index}").tap { |path| File.binwrite(path, body) }
      end
      oids = paths.empty? ? [] : Open3.capture2("git", "-C", repo.dir, "hash-object", "-w", "--stdin-paths", stdin_data: paths.join("\n")).first.split
      expected = oids.zip(texts).to_h { |oid, body| [oid, body.b.force_encoding(Encoding::UTF_8)] }
      assert_equal expected, git.read_blobs(oids)
    end
  ensure
    repo&.destroy
  end

  def test_a_minitest_message_line_of_any_shape_stays_in_the_message
    Hegel.test do |tc|
      lines = tc.draw(arrays(from_regex(LINE_OF_ANY_SHAPE, fullmatch: true), max_size: 8))
      frames = Array.new(tc.draw(integers(min_value: 0, max_value: 3))) { [tc.draw(from_regex("lib/[a-z]{1,6}\\.rb", fullmatch: true)), tc.draw(integers(min_value: 1, max_value: 99))] }
      kind = tc.draw(sampled_from(%w[Failure Error]))
      # Only the indented frames that end an error are its backtrace, so an
      # error message that ends on one would lose it.
      lines << "end" if kind == "Error" && lines.last&.match?(/\A    .*:in /)
      body = kind == "Error" ? ["KeyError: first", *lines, *frames.map { |file, line| "    #{file}:#{line}:in 'g'" }] : ["first", *lines]
      stdout = ["  1) #{kind}:", "ATest#test_a#{" [a_test.rb:3]" if kind == "Failure"}:", *body, "", "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"].join("\n")

      result = JitCatch::MinitestParser.parse(stdout, "")["tests"].fetch("ATest#test_a")

      assert_equal ["first", *lines].join("\n").rstrip, result["message"]
      assert_equal kind == "Error" ? frames : [["a_test.rb", 3]], result["backtrace"].map { |item| [item["file"], item["line"]] }
    end
  end
end
