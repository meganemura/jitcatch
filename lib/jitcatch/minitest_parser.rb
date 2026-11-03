# frozen_string_literal: true

module JitCatch
  # Parses Minitest's verbose output (`ruby test.rb -v --seed 1`).
  class MinitestParser
    VERBOSE = /^(\S+) = \d+\.\d+ s = ([.FES])$/.freeze
    ISSUE = /^\s+\d+\) (Failure|Error|Skip):\s*$/.freeze
    SUMMARY = /^\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips$/.freeze
    HEADER = /^(\S+?)(?:\s+\[(.+):(\d+)\])?:\s*$/.freeze
    FRAME = /^\s*(.+):(\d+):in [`']([^`']*)[`']/.freeze
    LETTERS = { "." => "pass", "F" => "fail", "E" => "error", "S" => "skip" }.freeze
    # The runner writes this where a worktree root was, so a message still
    # shows that a path stood there. Frames drop it to match the diff's paths.
    WORKTREE = "{worktree}/"

    def self.parse(stdout, stderr, normalizer: ->(text) { text })
      new(normalizer.call(stdout.to_s), normalizer.call(stderr.to_s)).parse
    end

    def initialize(stdout, stderr)
      @stdout = stdout.gsub("\r\n", "\n")
      @stderr = stderr.gsub("\r\n", "\n")
    end

    def parse
      tests = {}
      @stdout.each_line do |raw|
        line = raw.delete_suffix("\n")
        next unless (match = line.match(VERBOSE))

        tests[match[1]] = blank_result(LETTERS.fetch(match[2]))
      end

      issues(stdout_lines).each do |issue|
        tests[issue["name"]] = issue["result"]
      end

      summary = stdout_lines.any? { |line| line.match?(SUMMARY) }
      file_error = summary ? nil : error_from_streams
      if !summary && tests.empty? && file_error.nil?
        file_error = {
          "status" => "error",
          "error_class" => "RuntimeError",
          "message" => "minitest summary not found",
          "message_first_line" => "minitest summary not found",
          "backtrace" => []
        }
      end
      { "tests" => tests, "summary" => summary, "file_error" => file_error }
    end

    private

    def stdout_lines
      @stdout_lines ||= @stdout.lines.map { |line| line.delete_suffix("\n") }
    end

    def issues(lines)
      found = []
      index = 0
      while index < lines.length
        match = lines[index].match(ISSUE)
        unless match
          index += 1
          next
        end
        kind = match[1]
        block = []
        index += 1
        while index < lines.length && !lines[index].match?(ISSUE) && !lines[index].match?(SUMMARY)
          block << lines[index]
          index += 1
        end
        parsed = parse_issue(kind, block)
        found << parsed if parsed
      end
      found
    end

    def parse_issue(kind, block)
      header = block.shift.to_s
      match = header.match(HEADER)
      return nil unless match

      name = match[1]
      frames = []
      frames << { "file" => match[2].delete_prefix(WORKTREE), "line" => match[3].to_i } if match[2]
      message_lines = []
      error_class = kind == "Failure" ? "Minitest::Assertion" : nil
      block.each do |line|
        if (frame = line.match(FRAME))
          frames << { "file" => frame[1].delete_prefix(WORKTREE), "line" => frame[2].to_i }
          next
        end
        if error_class.nil? && (err = line.match(/\A([A-Za-z0-9_:]+):\s*(.*)\z/))
          error_class = err[1]
          message_lines << err[2]
          next
        end
        message_lines << line
      end
      status = { "Failure" => "fail", "Error" => "error", "Skip" => "skip" }.fetch(kind)
      message = message_lines.join("\n").strip
      message = message.lines.first(20).join.rstrip
      {
        "name" => name,
        "result" => {
          "status" => status,
          "error_class" => error_class,
          "message" => message,
          "message_first_line" => first_line(message),
          "backtrace" => frames.first(15)
        }
      }
    end

    def error_from_streams
      text = @stderr.strip
      text = @stdout.strip if text.empty?
      return nil if text.empty?

      error_class = if text.include?("LoadError") || text.include?("cannot load such file")
        "LoadError"
      elsif text.include?("SyntaxError") || text.include?("syntax error")
        "SyntaxError"
      elsif (match = text.match(/\(([A-Za-z0-9_:]+)\)\s*\z/))
        match[1]
      else
        "RuntimeError"
      end
      frames = []
      text.each_line do |line|
        next unless (frame = line.match(FRAME))

        frames << { "file" => frame[1].delete_prefix(WORKTREE), "line" => frame[2].to_i }
      end
      message = text.lines.map(&:strip).reject(&:empty?).first.to_s
      {
        "status" => "error",
        "error_class" => error_class,
        "message" => message,
        "message_first_line" => first_line(message),
        "backtrace" => frames.first(15)
      }
    end

    def blank_result(status)
      {
        "status" => status,
        "error_class" => nil,
        "message" => "",
        "message_first_line" => "",
        "backtrace" => []
      }
    end

    def first_line(message)
      message.to_s.lines.map(&:strip).reject(&:empty?).first.to_s[0, 180]
    end
  end
end
