# frozen_string_literal: true

module JitCatch
  # The result a parser gives each test, and the one it gives a file that
  # fails before any test reports.
  module Failure
    module_function

    FRAME = /^\s*(?:# )?(.+):(\d+):in [`']([^`']*)[`']/.freeze
    # The runner writes this where a worktree root was, so a message still
    # shows that a path stood there. Frames drop it to match the diff's paths.
    WORKTREE = "{worktree}/"
    # Where the runner copies the tests directory in each worktree.
    TESTS_COPY = /#{Regexp.escape(WORKTREE)}\.jitcatch(?![\w.-])/.freeze
    MESSAGE_LINES = 20
    FRAMES = 15

    # +cause+ is the error the failing one was raised from, when the
    # framework printed it: {"error_class", "message"}.
    def result(status, error_class, message, frames, cause: nil)
      message = message.to_s.strip.lines.first(MESSAGE_LINES).join.rstrip
      {
        "status" => status,
        "error_class" => error_class,
        "message" => message,
        "message_first_line" => first_line(message),
        "backtrace" => frames.first(FRAMES),
        "cause" => cause
      }
    end

    # A test reads its own files from the copy, and the rerun line names
    # +tests+, so a message names +tests+ where it named the copy.
    def naming_tests(result, tests)
      return nil if result.nil?

      named = ->(text) { text.to_s.gsub(TESTS_COPY) { tests } }
      message = named.call(result["message"])
      cause = result["cause"] && result["cause"].merge("message" => named.call(result["cause"]["message"]))
      result.merge("message" => message, "message_first_line" => first_line(message), "cause" => cause)
    end

    def passed(status)
      result(status, nil, "", [])
    end

    def frame(file, line)
      { "file" => file.delete_prefix(WORKTREE).delete_prefix("./"), "line" => line.to_i }
    end

    def frames_in(lines)
      lines.filter_map { |line| (match = line.match(FRAME)) && frame(match[1], match[2]) }
    end

    # What a process printed when it stopped before its framework reported.
    def from_streams(stdout, stderr)
      text = stderr.strip
      text = stdout.strip if text.empty?
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
      result("error", error_class, text.lines.map(&:strip).reject(&:empty?).first, frames_in(text.lines))
    end

    def first_line(message)
      message.to_s.lines.map(&:strip).reject(&:empty?).first.to_s[0, 180]
    end
  end
end
