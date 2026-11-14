# frozen_string_literal: true
# rbs_inline: enabled

module JitCatch
  # The result a parser gives each test, and the one it gives a file that
  # fails before any test reports.
  module Failure
    module_function

    FRAME = /^\s*(?:# )?(.+):(\d+):in [`']([^`']*)[`']/.freeze #: Regexp
    # The runner writes this where a worktree root was, so a message still
    # shows that a path stood there. Frames drop it to match the diff's paths.
    WORKTREE = "{worktree}/" #: String
    # Where the runner copies the tests directory in each worktree.
    TESTS_COPY = /#{Regexp.escape(WORKTREE)}\.jitcatch(?![\w.-])/.freeze #: Regexp
    COPY_FRAME = %r{\A\.jitcatch/}.freeze #: Regexp
    # Ruby names the file it was started on by the path it was given, so the
    # error report of a file that fails to load starts a line with the copy's
    # relative path. Elsewhere a relative path may be what a test compared.
    COPY_PATH = %r{^(\s*(?:from )?)\.jitcatch/(?=\S+?:\d+:in )}.freeze #: Regexp
    MESSAGE_LINES = 20 #: Integer
    FRAMES = 15 #: Integer

    # +cause+ is the error the failing one was raised from, when the
    # framework printed it: {"error_class", "message"}.
    #: (String status, String? error_class, untyped message, Array[doc] frames, ?cause: doc?) -> doc
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
    # +tests+, the tests directory from the repository root, so a message
    # names it after the root, and a frame names it, where either named the
    # copy. An absolute +tests+ is outside every worktree, so it stands alone.
    # +prefix+ is the directory the run ran in, from the worktree root, as
    # `ruby/`, where the copy sits and from where +tests+ is named.
    #: (doc? result, String tests, ?String prefix) -> doc?
    def naming_tests(result, tests, prefix = "")
      return nil if result.nil?

      copy = prefix.empty? ? TESTS_COPY : /#{Regexp.escape("#{WORKTREE}#{prefix}")}\.jitcatch(?![\w.-])/
      copy_frame = prefix.empty? ? COPY_FRAME : %r{\A(?:#{Regexp.escape(prefix)})?\.jitcatch/}
      rooted = tests.start_with?("/") ? tests : "#{WORKTREE}#{prefix}#{tests}"
      named = ->(text) { text.to_s.gsub(copy) { rooted }.gsub(COPY_PATH) { "#{$1}#{tests}/" } }
      message = named.call(result["message"])
      cause = result["cause"] && result["cause"].merge("message" => named.call(result["cause"]["message"]))
      frames = Array(result["backtrace"]) #: Array[doc]
      backtrace = frames.map { |frame| frame.merge("file" => frame["file"].sub(copy_frame) { "#{tests}/" }) }
      result.merge("message" => message, "message_first_line" => first_line(message), "cause" => cause, "backtrace" => backtrace)
    end

    #: (String status) -> doc
    def passed(status)
      result(status, nil, "", [])
    end

    #: (String file, String | Integer line) -> doc
    def frame(file, line)
      { "file" => file.delete_prefix(WORKTREE).delete_prefix("./"), "line" => line.to_i }
    end

    #: (Array[String] lines) -> Array[doc]
    def frames_in(lines)
      lines.filter_map { |line| (match = line.match(FRAME)) && frame(match[1], match[2]) }
    end

    # What a process printed when it stopped before its framework reported.
    #: (String stdout, String stderr) -> doc?
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

    #: (untyped message) -> String
    def first_line(message)
      message.to_s.lines.map(&:strip).reject(&:empty?).first.to_s[0, 180]
    end
  end
end
