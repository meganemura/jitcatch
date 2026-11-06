# frozen_string_literal: true

module JitCatch
  module Render
    module_function

    LONG_LINE = 100
    WINDOW = 30
    DIFF_KEYS = 4
    # The element diff keeps a table of this many cells.
    MAX_ELEMENT_PAIRS = 250_000

    def context_text(doc)
      lines = []
      lines << "jitcatch context"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
      lines.concat(warning_lines(doc))
      lines << "existing_tests #{doc["existing_tests_via"]}"
      if doc["intent"].empty?
        lines << "intent: (none)"
      else
        lines << "intent:"
        doc["intent"].each { |line| lines << "  #{line}" }
      end
      lines << "files:"
      if doc["files"].empty?
        lines << "  (none)"
      else
        doc["files"].each { |file| lines << "  #{file["status"]} #{file["file"]}" }
      end
      lines.concat(dependency_lines(Array(doc["dependencies"])))
      lines.concat(constant_lines(doc["constants"]))
      lines.concat(method_lines(doc["methods"]))
      lines.concat(entrypoint_lines(doc["entrypoints"]))
      skipped = Array(doc["factories_skipped"])
      unless skipped.empty?
        lines << "factories_skipped:"
        skipped.each { |factory| lines << "  #{factory["file"]}:#{factory["line"]} factory#{factory["name"] && " :#{factory["name"]}"}: #{factory["reason"]}" }
      end
      unless doc["parse_errors"].empty?
        lines << "parse_errors:"
        doc["parse_errors"].each { |err| lines << "  #{err["ref"]} #{err["file"]} #{err["message"]}" }
      end
      finish(lines)
    end

    def context_json(doc)
      { "command" => "context" }.merge(doc)
    end

    def run_text(doc)
      lines = []
      lines << untested_line(doc) if Assessor.untested_run?(doc)
      lines << "jitcatch run"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
      lines.concat(warning_lines(doc))
      lines << "reruns #{doc["reruns"]}"
      lines << "timeout_s #{doc["timeout_s"]}"
      lines << "serial" if doc["serial"]
      lines << "numbered_databases #{doc["numbered_databases"].join(" ")}" unless doc["numbered_databases"].to_a.empty?
      lines << "env #{doc["env"].join(" ")}" unless doc["env"].to_a.empty?
      lines << "env_unset #{doc["env_unset"].join(" ")}" unless doc["env_unset"].to_a.empty?
      doc.fetch("bundle", {}).each { |side, bundle| lines << "bundle #{side} #{bundle}" unless bundle == "none" }
      lines << "test_files_omitted #{doc["test_files_omitted"]}" unless doc["test_files_omitted"].to_i.zero?
      lines << "tests:"
      if doc["tests"].empty?
        lines << "  (none)"
      else
        doc["tests"].each do |test|
          lines << "  #{test_line(test)}"
          lines.concat(rerun_lines(test)) if test["disposition"] == "flaky"
          lines.concat(timeout_lines(test, doc))
          lines.concat(base_failure_lines(test))
        end
      end
      lines << counts_line(doc["counts"])
      lines.concat(assess_body(doc))
      finish(lines)
    end

    def run_json(doc)
      doc
    end

    def setup_failed_text(doc)
      load = doc["stage"] == "load"
      lines = [load ? "jitcatch: every candidate file failed to load on both sides, so no row can tell base from head" : "jitcatch: setup failed, so no test ran; a test cannot pass or fail on a side that cannot load"]
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
      lines << "ruby #{doc.dig("ruby", "version")} #{doc.dig("ruby", "path")}"
      doc["setup_failed"].each do |failure|
        lines << "#{load ? "load" : "setup"} #{failure["side"]} failed: #{failure["command"]}"
        failure["stderr"].each { |line| lines << "  #{line}" }
        names = failure["not_passed"]
        lines << "  not passed: #{names.join(" ")} (add #{env_flags(names)})" unless names.empty?
      end
      lines << if load
        rails = " A file git ignores, such as config/master.key, is not in the checkouts jitcatch makes; pass its value with --env, such as RAILS_MASTER_KEY." if doc["rails_app"]
        "Run that command from the repository root with that side checked out, fix what it says (often a database, a credential, or a service the app needs at boot), and run jitcatch again.#{rails}"
      else
        "Run that command with that Ruby in a checkout of that side, fix what it says (often `bundle install` there; a bundle installed for another Ruby reads as gems not installed), and run jitcatch again."
      end
      finish(lines)
    end

    def assess_text(doc)
      lines = []
      lines << "jitcatch assess"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
      lines.concat(warning_lines(doc))
      lines << counts_line(doc["counts"])
      lines.concat(assess_body(doc))
      finish(lines)
    end

    def assess_json(doc)
      {
        "command" => "assess",
        "version" => doc["version"],
        "base" => doc["base"],
        "head" => doc["head"],
        "warnings" => Array(doc["warnings"]),
        "counts" => doc["counts"],
        "candidates" => candidate_rows(doc)
      }
    end

    def dump(obj)
      JSON.pretty_generate(obj) + "\n"
    end

    def warning_lines(doc)
      Array(doc["warnings"]).map { |warning| "warning: #{warning}" }
    end

    def dependency_lines(dependencies)
      return [] if dependencies.empty?

      ["dependencies:", *dependencies.map { |dep| "  #{dep["gem"]} #{dep["old"] || "(none)"} -> #{dep["new"] || "(none)"}" }]
    end

    def constant_lines(constants)
      if constants.empty?
        ["constants: (none)"]
      else
        lines = ["constants:"]
        constants.each do |const|
          moved = const["moved_from"] ? " moved_from=#{const["moved_from"]}" : ""
          lines << "  [#{const["id"]}] #{const["change"]} #{const["name"]} #{const["file"]}:#{const["start_line"]}#{moved}"
          lines << "    old: #{const["old_source"] || "(none)"}"
          lines << "    new: #{const["new_source"] || "(none)"}"
          readers = const["readers"].empty? ? "(none)" : const["readers"].join(", ")
          lines << "    readers: #{readers}"
        end
        lines
      end
    end

    def method_lines(methods)
      if methods.empty?
        ["methods: (none)"]
      else
        lines = ["methods:"]
        methods.each do |method|
          via = method["via_constant"] ? " via=#{method["via_constant"]}" : ""
          via += " moved_from=#{method["moved_from"]}" if method["moved_from"]
          lines << "  [#{method["id"]}] #{method["change"]} #{method["name"]} #{method["file"]}:#{method["start_line"]}-#{method["end_line"]} signature=#{method["signature"]} visibility=#{method["visibility"]}#{via}"
          lines << "    callsites: #{format_callsites(method)}"
          unless method["reachable_from"].empty?
            lines << "    reachable_from: #{method["reachable_from"].join(", ")}"
          end
          unless method["dynamic_callers"].to_a.empty?
            lines << "    dynamic_callers: #{method["dynamic_callers"].map { |caller| "#{caller["from"]} (#{caller["name"]})" }.join(", ")}"
          end
          lines << "    built_by: #{method["builders"].join(", ")}" unless method["builders"].to_a.empty?
          lines << "    run_by: #{method["run_by"].join(", ")} (#{method["callbacks"].join(", ")})" unless method["run_by"].to_a.empty?
          lines << "    tests: #{format_tests(method["existing_tests"])}"
          unless method["entry_point_tests"].empty?
            hits = method["entry_point_tests"].map { |hit| "#{hit["file"]} via #{hit["entry_points"].join(", ")}" }
            lines << "    entry_point_tests: #{hits.join("; ")}"
          end
          lines.concat(source_lines(method))
        end
        lines
      end
    end

    def entrypoint_lines(entrypoints)
      return ["entrypoints: (none)"] if entrypoints.empty?

      lines = []
      entrypoints.each do |entry|
        lines << "entrypoints #{entry["class"]}:"
        entry["methods"].each { |method| lines << "  #{method["name"]} #{method["role"]}" }
        lines << "  (+#{entry["omitted"]} more)" if entry["omitted"].to_i.positive?
      end
      lines
    end

    def format_callsites(method)
      return "(none)" if method["callsites"].empty?

      text = method["callsites"].map { |site| "#{site["file"]}:#{site["line"]} #{site["enclosing"]}" }.join("; ")
      omitted = method["callsites_omitted"].to_i
      omitted.positive? ? "#{text} (+#{omitted} more)" : text
    end

    def format_tests(tests)
      return "(none)" if tests.empty?

      tests.map { |test|
        if test["via"] == "coverage"
          "#{test["file"]} coverage #{test["test"]}"
        elsif %w[builder callback].include?(test["via"])
          "#{test["file"]} via #{test["calls"].join(", ")}"
        else
          "#{test["file"]} grep"
        end
      }.join("; ")
    end

    def source_lines(method)
      old_src = method["old_source"]
      new_src = method["new_source"]
      if old_src == new_src
        ["    source:", *Text.indent(old_src, 6).split("\n")]
      else
        lines = []
        lines << "    old:"
        lines.concat(Text.indent(old_src, 6).split("\n"))
        lines << "    new:"
        lines.concat(Text.indent(new_src, 6).split("\n"))
        lines
      end
    end

    def test_line(test)
      method = test["method_id"] ? " #{test["method_id"]}" : ""
      place = test["line"] ? "#{test["file"]}:#{test["line"]}" : test["file"]
      "#{test["id"]} #{test["disposition"]} #{test["name"]} #{place}#{method}"
    end

    # A flaky row says which run moved and how: the outcome, or only the
    # message, as a random id in a printed record does. Base reruns only
    # when head failed the same way each time.
    def rerun_lines(test)
      head = test["head"] || {}
      head_lines = Text.message_lines(head["message"])
      reruns = Array(test["reruns"]).each_with_index.map do |rerun, index|
        # The first line that moved says why the row is flaky.
        moved = Text.message_lines(rerun["message"]).find { |line| !head_lines.include?(line) }
        same = rerun.values_at("status", "error_class") == head.values_at("status", "error_class") && moved
        outcome = [rerun["status"], rerun["error_class"], ("(same outcome, message differs)" if same), moved || rerun["message_first_line"]]
        cut_line("    rerun #{index + 1}: #{outcome.reject { |part| part.to_s.empty? }.join(" ")}")
      end
      base = Array(test["base_reruns"]).each_with_index.map do |rerun, index|
        outcome = [rerun["status"], rerun["error_class"], rerun["message_first_line"]].reject { |part| part.to_s.empty? }
        cut_line("    base rerun #{index + 1}: #{outcome.join(" ")}")
      end
      reruns + base
    end

    # A row that failed on base is no candidate, so nothing else in the
    # text says what went wrong there.
    def base_failure_lines(test)
      base = test["base"]
      return [] unless test["disposition"] == "fail_on_base" && base && base["status"] != "timeout"

      first, *rest = message_lines(base)
      outcome = [base["status"], base["error_class"], first].reject { |part| part.to_s.empty? }
      ["    base: #{outcome.join(" ")}", *rest.map { |line| "      #{line}" }]
    end

    def untested_line(doc)
      causes = Assessor::UNTESTED_CAUSES.keys & doc["tests"].flat_map { |test| Assessor.untested_causes(test) }
      "jitcatch: no row ran to a result on both sides (#{doc["untested"]} of #{doc["tests"].size} #{causes.join(" or ")}), so this run cannot tell base from head"
    end

    # A child that waits on the network or on a command an environment
    # variable names often lacks a name the parent has, which a longer
    # timeout does not fix, so the row names those first: a name --env
    # passed that the shell did not set, then a name jitcatch did not pass.
    # Only a Rails app loads db/schema.rb in each new checkout.
    def timeout_lines(test, doc)
      sides = %w[base head].select { |side| test.dig(side, "status") == "timeout" }
      return [] if sides.empty?

      unset = Array(doc["env_unset"])
      not_passed = Array(doc["env_not_passed"])
      missing = [
        ("#{env_flags(unset)} passed nothing, because #{unset.join(" ")} #{unset.one? ? "is" : "are"} not set, so set #{them(unset)} if the file needs #{them(unset)}" unless unset.empty?),
        ("jitcatch did not pass #{not_passed.join(" ")}, so add #{env_flags(not_passed)} if the file needs #{them(not_passed)}" unless not_passed.empty?)
      ].compact
      wait = missing.empty? ? "raise --timeout if the file needs longer" : "#{missing.join("; ")}, then raise --timeout if it needs longer"
      rails = ", as a Rails app's first run in a new checkout can (it loads db/schema.rb)" if doc["rails_app"]
      ["    hint: #{sides.join(" and ")} timed out after #{doc["timeout_s"]}s; #{wait}#{rails}"]
    end

    def env_flags(names)
      names.map { |name| "--env #{name}" }.join(" ")
    end

    def them(names)
      names.one? ? "it" : "them"
    end

    # The rerun line runs in the reader's shell, so it names the variables
    # the run took from jitcatch's, and no value: a DATABASE_URL can hold a
    # password, and a report is pasted where others read it.
    def rerun_env_line(doc)
      names = Array(doc["env"])
      return nil if names.empty?

      unset = Array(doc["env_unset"])
      "    rerun env: reads #{names.join(" ")} from your shell, as jitcatch run did#{"; #{unset.join(" ")} #{unset.one? ? "was" : "were"} not set for the run" unless unset.empty?}"
    end

    def counts_line(counts)
      "counts generated=#{counts["generated"]} no_signal=#{counts["no_signal"]} fail_on_base=#{counts["fail_on_base"]} candidates=#{counts["candidates"]} flaky=#{counts["flaky"]} discarded=#{counts["discarded"]} reported=#{counts["reported"]}"
    end

    def assess_body(doc)
      rows = candidate_rows(doc)
      lines = ["assess:"]
      env_line = rerun_env_line(doc)
      if rows.empty?
        lines << "  (none)"
        return lines
      end
      rows.each do |row|
        method = row["method_id"] || "-"
        lines << "  #{row["candidate_id"]} #{row["name"]} base=#{row["base_status"]} head=#{row["head_status"]} #{method} #{row["tags"].join(",")}"
        lines << "    related guess: #{row["method_id"] || "none"} of #{row["method_ids"].join(",")}" if row["method_ids"].size > 1
        if (dynamic = row["dynamic_call"])
          lines << "    related: none, #{dynamic["from"]} sends #{dynamic["name"]} to a receiver the source does not name"
        end
        row["message_lines"].each { |line| lines << "    #{line}" }
        lines << "    cause: #{cause_line(row["cause"])}" if row["cause"]
        lines << "    rerun: #{row["rerun"]}" if row["rerun"]
        lines << env_line if row["rerun"] && env_line
      end
      lines
    end

    def candidate_rows(doc)
      doc["tests"].select { |test| test["classification"] == "candidate" }.sort_by { |test| test["id"] }.map { |test|
        {
          "candidate_id" => test["candidate_id"],
          "id" => test["id"],
          "file" => test["file"],
          "line" => test["line"],
          "name" => test["name"],
          "rerun" => test["rerun"],
          "base_status" => test.dig("base", "status"),
          "head_status" => test.dig("head", "status"),
          "method_id" => test["method_id"],
          "method_ids" => Array(test["method_ids"]),
          "dynamic_call" => test["dynamic_call"],
          "tags" => test["tags"],
          "disposition" => test["disposition"],
          "message_first_line" => test.dig("head", "message_first_line").to_s,
          "message" => test.dig("head", "message").to_s,
          "message_lines" => message_lines(test["head"]),
          "cause" => test.dig("head", "cause")
        }
      }
    end

    def cause_line(cause)
      cause && [cause["error_class"], Failure.first_line(cause["message"])].reject(&:empty?).join(": ")
    end

    # A row keeps each line to this many characters; one Array printed
    # whole can fill tens of kilobytes.
    MESSAGE_LINE = 300

    def message_lines(head)
      return [] if head.nil?

      failure_lines(head).map { |line| cut_line(line) }
    end

    # The end of a line often holds what differs, after a path or a value
    # both sides share, so a cut leaves out the middle.
    def cut_line(line)
      return line if line.length <= MESSAGE_LINE

      half = MESSAGE_LINE / 2
      left = line.length - MESSAGE_LINE
      "#{line[0, half]}... (+#{left} #{left == 1 ? "character" : "characters"}; the whole message is in --json) ...#{line[-half..]}"
    end

    def failure_lines(head)

      lines = head["message"].to_s.lines.map(&:strip).reject(&:empty?)
      if lines[1]&.match?(/\AActual:/)
        lines.first(2)
      elsif lines[0]&.end_with?("exception expected, not") && lines[1]&.start_with?("Class: <")
        # assert_raises names the error that came on the next two lines.
        lines.first(3)
      elsif lines[0]&.start_with?("expected: ") && lines[1]&.start_with?("got: ")
        # RSpec's eq and eql print each side on its own line.
        expected = lines[0].delete_prefix("expected: ")
        actual = lines[1].delete_prefix("got: ")
        [expected, actual].all? { |text| text.length <= LONG_LINE } ? lines.first(2) : changed_pair(expected, actual)
      elsif lines[0]&.start_with?("expected ") && lines[1]&.start_with?("got ")
        # RSpec's be and equal compare identity and print each side unlabeled.
        lines.first(2)
      elsif lines[1]&.start_with?("expected: ") && lines[2]&.start_with?("got: ")
        # rspec-mocks names the call, then the arguments it wanted and got.
        lines.first(3)
      elsif lines[0] == "--- expected" && lines[1] == "+++ actual"
        # Minitest prints a unified diff when either side spans lines or is
        # long; its header says nothing, so show the first removed and added line.
        # A context line starts with a space, which strip would take away.
        changed = head["message"].to_s.lines.map(&:rstrip).reject(&:empty?).drop(2)
        removed = changed.index { |line| line.start_with?("-") }
        added = changed.index { |line| line.start_with?("+") }
        if removed && added && removed < added && changed[removed...added].all? { |line| line.start_with?("-") }
          changed_pair(changed[removed][1..], changed[added][1..])
        else
          # Lines that do not replace each other share no column.
          [removed, added].compact.map { |index| "#{changed[index][0]}#{shortened(changed[index][1..])}" }
        end
      elsif lines[0] && lines[0].length > MESSAGE_LINE && (changed = rspec_diff_changes(head["message"].to_s))
        [lines[0], *changed]
      else
        lines.first(1)
      end
    end

    # The removed and added lines of the Diff RSpec prints under a matcher's
    # message, such as have_attributes, whose one line shows both Hashes.
    def rspec_diff_changes(message)
      diff = message.lines.map(&:rstrip).drop_while { |line| line != "Diff:" }.drop(1)
      changed = diff.select { |line| line.match?(/\A[-+](?![-+]{2} )/) }
      changed.empty? ? nil : changed.first(2 * DIFF_KEYS)
    end

    # A long line, such as a whole Hash on one line, is hard to compare by
    # eye. Show the Hash entries that differ, or else a window around the
    # first column that differs. `message` in `--json` keeps the full text.
    def changed_pair(expected, actual)
      return ["-#{expected}", "+#{actual}"] if [expected, actual].all? { |text| text.length <= LONG_LINE }

      hash_entry_lines(expected, actual) || array_element_lines(expected, actual) || column_lines(expected, actual)
    end

    def shortened(line)
      line.length > LONG_LINE ? "#{line[0, (2 * WINDOW) + 1]}..." : line
    end

    # The elements one Array literal has and the other lacks, by index, from
    # a longest common subsequence, so one inserted element is one line and
    # not a shift of every element after it.
    def array_element_lines(expected, actual)
      old_items = array_elements(expected)
      new_items = array_elements(actual)
      return nil unless old_items && new_items && old_items.size * new_items.size <= MAX_ELEMENT_PAIRS

      changes = element_changes(old_items, new_items)
      return nil if changes.empty?

      shown = changes.first(DIFF_KEYS)
      more = changes.size > DIFF_KEYS ? " (+#{changes.size - DIFF_KEYS} more)" : ""
      lines = ["array elements differ: #{shown.map { |index, _, _| "[#{index}]" }.join(", ")}#{more}"]
      shown.each do |index, old_item, new_item|
        old_entry = "[#{index}] #{old_item}" if old_item
        new_entry = "[#{index}] #{new_item}" if new_item
        lines.concat(old_entry && new_entry ? changed_pair(old_entry, new_entry) : [old_entry && "-#{old_entry}", new_entry && "+#{new_entry}"].compact)
      end
      lines
    end

    def array_elements(text)
      result = Prism.parse(text)
      body = result.success? ? result.value.statements.body : []
      return nil unless body.size == 1 && body.first.is_a?(Prism::ArrayNode)

      body.first.elements.map(&:slice)
    end

    # Each change as [index, old element, new element]: a removed element
    # has no new one and an added one no old one. Within one run of changes,
    # the removed and added elements pair up in order, as replacements.
    def element_changes(old_items, new_items)
      lengths = Array.new(old_items.size + 1) { Array.new(new_items.size + 1, 0) }
      old_items.each_index.reverse_each do |i|
        new_items.each_index.reverse_each do |j|
          lengths[i][j] = old_items[i] == new_items[j] ? lengths[i + 1][j + 1] + 1 : [lengths[i + 1][j], lengths[i][j + 1]].max
        end
      end
      runs = [[[], []]]
      i = j = 0
      while i < old_items.size || j < new_items.size
        if i < old_items.size && j < new_items.size && old_items[i] == new_items[j]
          runs << [[], []]
          i += 1
          j += 1
        elsif j < new_items.size && (i == old_items.size || lengths[i][j + 1] > lengths[i + 1][j])
          runs.last[1] << [j, new_items[j]]
          j += 1
        else
          runs.last[0] << [i, old_items[i]]
          i += 1
        end
      end
      runs.flat_map do |removed, added|
        Array.new([removed.size, added.size].max) do |k|
          [(removed[k] || added[k]).first, removed[k]&.last, added[k]&.last]
        end
      end
    end

    def hash_entry_lines(expected, actual)
      old_entries = hash_entries(expected)
      new_entries = hash_entries(actual)
      return nil unless old_entries && new_entries

      keys = (old_entries.keys + new_entries.keys).uniq.reject { |key| old_entries[key] == new_entries[key] }
      return nil if keys.empty?

      lines = ["hash keys differ: #{keys.first(DIFF_KEYS).join(", ")}#{" (+#{keys.size - DIFF_KEYS} more)" if keys.size > DIFF_KEYS}"]
      keys.first(DIFF_KEYS).each do |key|
        old_entry = "#{key} => #{old_entries[key]}" if old_entries.key?(key)
        new_entry = "#{key} => #{new_entries[key]}" if new_entries.key?(key)
        lines.concat(old_entry && new_entry ? changed_pair(old_entry, new_entry) : [old_entry && "-#{old_entry}", new_entry && "+#{new_entry}"].compact)
      end
      lines
    end

    # The entries of a Hash literal as written by `inspect`, keyed by the
    # key's text, or nil when the text is not one Hash literal.
    def hash_entries(text)
      result = Prism.parse(text)
      body = result.success? ? result.value.statements.body : []
      return nil unless body.size == 1 && body.first.is_a?(Prism::HashNode)
      return nil unless body.first.elements.all?(Prism::AssocNode)

      body.first.elements.to_h { |assoc| [assoc.key.slice.delete_suffix(":"), assoc.value.slice] }
    end

    def column_lines(expected, actual)
      column = (0...[expected.length, actual.length].min).find { |index| expected[index] != actual[index] } || [expected.length, actual.length].min
      start = [column - WINDOW, 0].max
      lead = start.zero? ? "" : "..."
      window = ->(text) { "#{lead}#{text[start, (2 * WINDOW) + 1]}#{"..." if text.length > start + (2 * WINDOW) + 1}" }
      ["-#{window.call(expected)}", "+#{window.call(actual)}", "#{" " * (1 + lead.length + column - start)}^ column #{column + 1}"]
    end

    def finish(lines)
      "#{lines.join("\n")}\n"
    end
  end
end
