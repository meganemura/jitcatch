# frozen_string_literal: true

module JitCatch
  # Reads the report minitest_report.rb writes in a Minitest candidate's
  # process, and Minitest's output for an error that stopped the file.
  class MinitestParser
    HEADER = /^(\S.*?)(?:\s+\[(.+):(\d+)\])?:\s*$/.freeze
    STATUSES = { "F" => "fail", "E" => "error" }.freeze
    # minitest_report.rb prints the error an error was raised from under
    # this line, between the message and the frames.
    CAUSED_BY = "--- Caused by: ---"
    FINISHED = "finished"

    def self.parse(report, stdout, stderr, normalizer: ->(text) { text })
      new(report.to_s, normalizer.call(stdout.to_s), normalizer.call(stderr.to_s), normalizer).parse
    end

    def initialize(report, stdout, stderr, normalizer)
      @report = report
      @stdout = stdout.gsub("\r\n", "\n")
      @stderr = stderr.gsub("\r\n", "\n")
      @normalizer = normalizer
    end

    def parse
      tests = {}
      summary = false
      @report.each_line do |raw|
        # A process killed while it wrote leaves its last line cut.
        next unless raw.end_with?("\n")

        line = raw.chomp
        next summary = true if line == FINISHED

        name, code, text = line.split("\t", 3).map { |field| readable(field.undump) }
        tests[name] = result(code, @normalizer.call(text.to_s))
      end

      file_error = summary ? nil : Failure.from_streams(@stdout, @stderr)
      if !summary && tests.empty? && file_error.nil?
        file_error = Failure.result("error", "RuntimeError", "minitest summary not found", [])
      end
      { "tests" => tests, "lines" => {}, "summary" => summary, "file_error" => file_error }
    end

    private

    # A message can hold bytes that are not UTF-8; they read as "?", as in the
    # streams the runner reads.
    def readable(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("?")
    end

    # The text is what Minitest prints for a result in its summary: the
    # failure's label line, the test's location, then the message.
    def result(code, text)
      status = STATUSES[code]
      return Failure.passed(code == "S" ? "skip" : "pass") unless status

      parse_issue(status, text.gsub("\r\n", "\n").lines(chomp: true).drop(1))
    end

    def parse_issue(status, block)
      match = block.shift.to_s.match(HEADER)
      frames = []
      frames << Failure.frame(match[2], match[3]) if match&.[](2)
      body, backtrace = status == "error" ? split_backtrace(block) : [block, []]
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
      error_class = "Minitest::Assertion" if status == "fail"
      if status == "error" && (err = message_lines.first.to_s.match(/\A([A-Za-z0-9_:]+): ?(.*)\z/))
        error_class = err[1]
        message_lines[0] = err[2]
      end
      cause = nil
      if status == "error" && (at = message_lines.index(CAUSED_BY))
        cause_lines = message_lines.drop(at + 1)
        message_lines = message_lines.take(at)
        named = cause_lines.first.to_s.match(/\A([A-Za-z0-9_:]+): ?(.*)\z/)
        cause = { "error_class" => named ? named[1] : "", "message" => [named ? named[2] : cause_lines.first.to_s, *cause_lines.drop(1)].join("\n") }
      end
      Failure.result(status, error_class, message_lines.join("\n"), frames + Failure.frames_in(backtrace), cause: cause)
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
