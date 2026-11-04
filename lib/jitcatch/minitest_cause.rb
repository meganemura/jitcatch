# frozen_string_literal: true

# Loaded into a Minitest candidate's process with `ruby -r`, never into
# jitcatch itself. Minitest prints an error's class, message, and frames,
# but not the error it was raised from, so this puts that error's class and
# message between the message and the frames, under the line RSpec prints
# for the same thing.
begin
  require "minitest"
rescue LoadError
  # A bundle without minitest is named by the bundle check, not here.
else
  Minitest::UnexpectedError.prepend(Module.new do
    def message
      text = super
      cause = error.cause
      head = "#{error.class}: #{error.message}"
      return text unless cause && text.start_with?(head)

      "#{head}\n--- Caused by: ---\n#{cause.class}: #{cause.message}#{text[head.length..]}"
    end
  end)
end
