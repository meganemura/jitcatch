# frozen_string_literal: true

module JitCatch
  # Parses Minitest's verbose output (`ruby test.rb -v --seed 1`).
  class MinitestParser
    # minitest/spec names a test after its description, spaces included.
    VERBOSE = /^(\S.*?) = \d+\.\d+ s = ([.FES])$/.freeze
    ISSUE = /^\s+\d+\) (Failure|Error|Skip):\s*$/.freeze
    SUMMARY = /^\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips$/.freeze
    HEADER = /^(\S.*?)(?:\s+\[(.+):(\d+)\])?:\s*$/.freeze
    LETTERS = { "." => "pass", "F" => "fail", "E" => "error", "S" => "skip" }.freeze

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

        tests[match[1]] = Failure.passed(LETTERS.fetch(match[2]))
      end

      issues(stdout_lines).each do |issue|
        tests[issue["name"]] = issue["result"]
      end

      summary = stdout_lines.any? { |line| line.match?(SUMMARY) }
      file_error = summary ? nil : Failure.from_streams(@stdout, @stderr)
      if !summary && tests.empty? && file_error.nil?
        file_error = Failure.result("error", "RuntimeError", "minitest summary not found", [])
      end
      { "tests" => tests, "lines" => {}, "summary" => summary, "file_error" => file_error }
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

      frames = []
      frames << Failure.frame(match[2], match[3]) if match[2]
      body, backtrace = kind == "Error" ? split_backtrace(block) : [block, []]
      message_lines = []
      quoting = false
      body.each do |line|
        # assert_raises prints the frames of the error it got between these
        # two lines. The frames move to the backtrace, so the lines go too.
        if line == "---Backtrace---" || (quoting && line.match?(/\A-+\z/))
          quoting = !quoting
          next
        end
        if quoting && (frame = line.match(Failure::FRAME))
          frames << Failure.frame(frame[1], frame[2])
          next
        end
        message_lines << line
      end
      error_class = "Minitest::Assertion" if kind == "Failure"
      if kind == "Error" && (err = message_lines.first.to_s.match(/\A([A-Za-z0-9_:]+): ?(.*)\z/))
        error_class = err[1]
        message_lines[0] = err[2]
      end
      status = { "Failure" => "fail", "Error" => "error", "Skip" => "skip" }.fetch(kind)
      { "name" => match[1], "result" => Failure.result(status, error_class, message_lines.join("\n"), frames + Failure.frames_in(backtrace)) }
    end

    # An error prints "Class: message", then each frame on a line of its own
    # indented four spaces. A message line can look like a frame, so only the
    # indented frames at the end of the block are the backtrace.
    def split_backtrace(block)
      lines = block.dup
      lines.pop while lines.last&.strip&.empty?
      at = lines.size
      at -= 1 while at.positive? && lines[at - 1].start_with?("    ") && lines[at - 1].match?(Failure::FRAME)
      [lines.take(at), lines.drop(at)]
    end
  end
end
