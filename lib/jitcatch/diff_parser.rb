# frozen_string_literal: true
# rbs_inline: enabled

module JitCatch
  # Parses `git diff --unified=0` text. Line numbers are 1-based, matching Prism.
  module DiffParser
    module_function

    #: (String? text) -> Array[doc]
    def parse(text)
      files = [] #: Array[doc]
      current = nil #: doc?
      text.to_s.each_line do |raw|
        line = raw.delete_suffix("\n")
        if line.start_with?("diff --git ")
          files << (current = { "old_path" => nil, "new_path" => nil, "hunks" => [] })
        elsif current && line.start_with?("--- ")
          current["old_path"] = clean_path(line[4..])
        elsif current && line.start_with?("+++ ")
          current["new_path"] = clean_path(line[4..])
        elsif current && (match = line.match(/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/))
          current["hunks"] << {
            "old_start" => match[1].to_i,
            "old_count" => (match[2] || "1").to_i,
            "new_start" => match[3].to_i,
            "new_count" => (match[4] || "1").to_i
          }
        end
      end
      files
    end

    #: (String? text) -> Array[doc]
    def name_status(text)
      text.to_s.lines.filter_map do |line|
        status, path = line.strip.split("\t", 2)
        next if path.nil? || path.empty?

        { "status" => status.to_s[0], "file" => path }
      end.sort_by { |entry| [entry["file"], entry["status"]] }
    end

    #: (String? raw) -> String?
    def clean_path(raw)
      path = raw.to_s.strip
      return nil if path == "/dev/null"

      path.sub(%r{\A[ab]/}, "")
    end

    #: (Integer start_line, Integer end_line, Array[doc] hunks, String side) -> bool
    def overlaps?(start_line, end_line, hunks, side)
      hunks.any? do |hunk|
        count = hunk["#{side}_count"]
        next false if count.zero?

        hunk_start = hunk["#{side}_start"]
        hunk_end = hunk_start + count - 1
        start_line <= hunk_end && end_line >= hunk_start
      end
    end
  end
end
