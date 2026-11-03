# frozen_string_literal: true

module JitCatch
  module Render
    module_function

    def context_text(doc)
      lines = []
      lines << "jitcatch context"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
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
      lines << "jitcatch run"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
      lines << "reruns #{doc["reruns"]}"
      lines << "timeout_s #{doc["timeout_s"]}"
      lines << "env #{doc["env"].join(" ")}" unless doc["env"].to_a.empty?
      doc.fetch("bundle", {}).each do |side, bundle|
        next if bundle["status"] == "none"

        lines << (bundle["message"].empty? ? "bundle #{side} #{bundle["status"]}" : "bundle #{side} #{bundle["status"]}: #{bundle["message"]}")
      end
      lines << "test_files_omitted #{doc["test_files_omitted"]}" unless doc["test_files_omitted"].to_i.zero?
      lines << "tests:"
      if doc["tests"].empty?
        lines << "  (none)"
      else
        doc["tests"].each do |test|
          lines << "  #{test_line(test)}"
          lines.concat(rerun_lines(test)) if test["disposition"] == "flaky"
        end
      end
      lines << counts_line(doc["counts"])
      lines.concat(assess_body(doc))
      finish(lines)
    end

    def run_json(doc)
      doc
    end

    def assess_text(doc)
      lines = []
      lines << "jitcatch assess"
      lines << "version #{doc["version"]}"
      lines << "base #{doc["base"]}"
      lines << "head #{doc["head"]}"
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
        "counts" => doc["counts"],
        "candidates" => candidate_rows(doc)
      }
    end

    def dump(obj)
      JSON.pretty_generate(obj) + "\n"
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
          lines << "  [#{const["id"]}] #{const["change"]} #{const["name"]} #{const["file"]}:#{const["start_line"]}"
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
          lines << "  [#{method["id"]}] #{method["change"]} #{method["name"]} #{method["file"]}:#{method["start_line"]}-#{method["end_line"]} signature=#{method["signature"]} visibility=#{method["visibility"]}#{via}"
          lines << "    callsites: #{format_callsites(method)}"
          unless method["reachable_from"].empty?
            lines << "    reachable_from: #{method["reachable_from"].join(", ")}"
          end
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
      "#{test["id"]} #{test["disposition"]} #{test["name"]} #{test["file"]}#{method}"
    end

    def rerun_lines(test)
      Array(test["reruns"]).each_with_index.map do |rerun, index|
        outcome = [rerun["status"], rerun["error_class"], rerun["message_first_line"]].reject { |part| part.to_s.empty? }
        "    rerun #{index + 1}: #{outcome.join(" ")}"
      end
    end

    def counts_line(counts)
      "counts generated=#{counts["generated"]} no_signal=#{counts["no_signal"]} fail_on_base=#{counts["fail_on_base"]} candidates=#{counts["candidates"]} flaky=#{counts["flaky"]} discarded=#{counts["discarded"]} reported=#{counts["reported"]}"
    end

    def assess_body(doc)
      rows = candidate_rows(doc)
      lines = ["assess:"]
      if rows.empty?
        lines << "  (none)"
        return lines
      end
      rows.each do |row|
        method = row["method_id"] || "-"
        lines << "  #{row["candidate_id"]} #{row["name"]} base=#{row["base_status"]} head=#{row["head_status"]} #{method} #{row["tags"].join(",")}"
        row["message_lines"].each { |line| lines << "    #{line}" }
      end
      lines
    end

    def candidate_rows(doc)
      doc["tests"].select { |test| test["classification"] == "candidate" }.sort_by { |test| test["id"] }.map { |test|
        {
          "candidate_id" => test["candidate_id"],
          "id" => test["id"],
          "file" => test["file"],
          "name" => test["name"],
          "base_status" => test.dig("base", "status"),
          "head_status" => test.dig("head", "status"),
          "method_id" => test["method_id"],
          "tags" => test["tags"],
          "disposition" => test["disposition"],
          "message_first_line" => test.dig("head", "message_first_line").to_s,
          "message_lines" => message_lines(test["head"])
        }
      }
    end

    def message_lines(head)
      return [] if head.nil?

      lines = head["message"].to_s.lines.map(&:strip).reject(&:empty?)
      if lines[1]&.match?(/\AActual:/)
        lines.first(2)
      elsif lines[0] == "--- expected" && lines[1] == "+++ actual"
        # Minitest prints a unified diff when either side spans lines or is
        # long; its header says nothing, so show the first removed and added line.
        changed = lines.drop(2)
        [changed.find { |line| line.start_with?("-") }, changed.find { |line| line.start_with?("+") }].compact
      else
        lines.first(1)
      end
    end

    def finish(lines)
      "#{lines.join("\n")}\n"
    end
  end
end
