# frozen_string_literal: true
# rbs_inline: enabled

# Loaded into a Minitest candidate's process with `ruby -r`, never into
# jitcatch itself. It writes each result to a report file for
# MinitestParser, since the lines Minitest prints for a test can be split or
# joined by what the test prints and by tests that run at once. It loads no
# library beyond minitest, so the candidate's process sees no other change.
begin
  require "minitest"
rescue LoadError
  # A bundle without minitest is named by the bundle check, not here.
else
  # Minitest prints an error's class, message, and frames, but not the
  # error it was raised from, so this puts that error's class and message
  # between the message and the frames, under the line RSpec prints for
  # the same thing.
  # The methods below sit in anonymous modules and classes, which RBS cannot
  # name, so their types are for the reader; Steep does not read this file.
  Minitest::UnexpectedError.prepend(Module.new do
    #: () -> String
    def message
      text = super
      cause = error.cause
      head = "#{error.class}: #{error.message}"
      return text unless cause && text.start_with?(head)

      "#{head}\n--- Caused by: ---\n#{cause.class}: #{cause.message}#{text[head.length..]}"
    end
  end)

  # One line per result: the test's name, its result code, and the text
  # Minitest prints for it (a passing test's location), each as a
  # String#dump literal and joined by tabs, then a last line once the run
  # finished. Each line is written as it comes, so a run that is killed
  # keeps the results it reported.
  jitcatch_report = Class.new(Minitest::AbstractReporter) do
    # Framework::REPORT, resolved before a test can change the directory.
    define_method(:initialize) { @io = File.open(File.expand_path(".jitcatch-report.json"), "wb").tap { |io| io.sync = true } }

    #: (Minitest::Result result) -> void
    def record(result)
      @io.write("#{[[result.class_name, result.name].join("#"), result.result_code, result.to_s].map(&:dump).join("\t")}\n")
    end

    #: () -> void
    def report
      @io.write("finished\n")
    end
  end

  Minitest.singleton_class.prepend(Module.new do
    # Plugins add their reporters here. Registering an extension instead
    # would stop Minitest 5 from loading the plugins of installed gems.
    define_method(:init_plugins) do |options|
      super(options)
      reporter << jitcatch_report.new
    end
  end)
end
