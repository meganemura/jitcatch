# frozen_string_literal: true

module JitCatch
  # Parses the report RSpec's json formatter writes (`--format json --out`).
  # One example is one test, named by its full description.
  class RSpecParser
    STATUSES = { "passed" => "pass", "pending" => "skip" }.freeze
    # RSpec raises these when an expectation does not hold, so they are a
    # claim the example made, as Minitest::Assertion is.
    FAILURES = %w[
      RSpec::Expectations::ExpectationNotMetError
      RSpec::Expectations::MultipleExpectationsNotMetError
      RSpec::Mocks::MockExpectationError
      RSpec::Core::Pending::PendingExampleFixedError
    ].freeze
    # --backtrace keeps gem frames, which tell a gem's error from the code's,
    # but RSpec's own frames say nothing about the code under test.
    OWN_FRAME = %r{/gems/rspec-(?:core|expectations|mocks|support)-[^/]+/|\A-e\z}.freeze
    # A raise_error failure repeats the backtrace of the error it got, after
    # this phrase. The frames move to the backtrace, so the phrase goes too.
    QUOTED_FRAME = /\A\s*# \S.*:\d+:in /.freeze
    QUOTED_HEADER = / with backtrace:\s*\z/.freeze
    # The backtrace goes on past the error's own frames into the error it
    # was raised from: this line, the class, then the message and the
    # frames indented under it.
    CAUSED_BY = "--- Caused by: ---"

    def self.parse(report, stdout, stderr, normalizer: ->(text) { text })
      new(report, normalizer.call(stdout.to_s), normalizer.call(stderr.to_s), normalizer).parse
    end

    def initialize(report, stdout, stderr, normalizer)
      @report = report
      @stdout = stdout
      @stderr = stderr
      @normalizer = normalizer
    end

    def parse
      doc = read_report
      return { "tests" => {}, "lines" => {}, "file_error" => stream_error } unless doc

      tests = {}
      lines = {}
      Array(doc["examples"]).sort_by { |example| example["line_number"].to_i }.each do |example|
        name = example["full_description"].to_s
        name = "#{name} (line #{example["line_number"]})" while tests.key?(name)
        tests[name] = result_of(example)
        lines[name] = example["line_number"]
      end
      file_error = tests.empty? ? outside_error(doc) : nil
      { "tests" => tests, "lines" => lines, "file_error" => file_error }
    end

    private

    def read_report
      return nil if @report.to_s.strip.empty?

      doc = JSON.parse(@report)
      doc.is_a?(Hash) ? doc : nil
    rescue JSON::ParserError
      nil
    end

    def result_of(example)
      status = STATUSES[example["status"]]
      return Failure.passed(status) if status

      exception = example["exception"] || {}
      error_class = exception["class"].to_s
      quoted, lines = @normalizer.call(exception["message"].to_s).lines.partition { |line| line.match?(QUOTED_FRAME) }
      backtrace = Array(exception["backtrace"]).map { |line| @normalizer.call(line.to_s) }
      at = backtrace.index(CAUSED_BY)
      own = frames(backtrace.take(at || backtrace.size))
      # The expectation's line comes first, then the frames of the error it
      # got, as Minitest prints an assert_raises failure.
      message = quoted.empty? ? lines.join : lines.join.sub(QUOTED_HEADER, "")
      Failure.result(FAILURES.include?(error_class) ? "fail" : "error", error_class, message, [*own.first(1), *frames(quoted), *own.drop(1)],
        cause: at && cause(backtrace.drop(at + 1)))
    end

    def cause(lines)
      message = lines.drop(1).take_while { |line| line.start_with?("  ") && !line.match?(Failure::FRAME) }
      { "error_class" => lines.first.to_s.delete_suffix(":"), "message" => message.map(&:strip).join("\n") }
    end

    def frames(backtrace)
      Failure.frames_in(Array(backtrace).map { |line| @normalizer.call(line.to_s) })
        .reject { |frame| frame["file"].match?(OWN_FRAME) }
    end

    # RSpec reports an error while it loads the file, or in a suite hook, as
    # a message outside every example: "Failure/Error: ...", then the error
    # class on a line of its own and the message indented under it.
    def outside_error(doc)
      return nil if doc.dig("summary", "errors_outside_of_examples_count").to_i.zero?

      text = @normalizer.call(Array(doc["messages"]).first.to_s)
      lines = text.lines.map(&:rstrip)
      at = lines.index { |line| line.match?(/\A[A-Z][\w:]*:\z/) }
      return Failure.result("error", "RuntimeError", text, frames(lines)) unless at

      message = lines.drop(at + 1).take_while { |line| line.start_with?("  ") }.map(&:strip).join("\n")
      Failure.result("error", lines[at].delete_suffix(":"), message, frames(lines))
    end

    def stream_error
      Failure.from_streams(@stdout, @stderr) ||
        Failure.result("error", "RuntimeError", "rspec report not found", [])
    end
  end
end
