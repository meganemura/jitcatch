# frozen_string_literal: true

require "json"
require "rbconfig"

require_relative "jittest/git_repo"
require_relative "jittest/source_index"
require_relative "jittest/diff_parser"
require_relative "jittest/changes"
require_relative "jittest/minitest_parser"
require_relative "jittest/assessor"
require_relative "jittest/runner"
require_relative "jittest/render"
require_relative "jittest/cli"

module JitTest
  VERSION = "0.1.0"

  class Error < StandardError; end
  class UsageError < Error; end
  class GitError < Error; end

  module Text
    module_function

    def cap_lines(text, limit: 40, head: 32, tail: 7)
      return nil if text.nil?
      parts = text.split("\n", -1)
      parts.pop if parts.last&.empty?
      return parts.join("\n") if parts.size <= limit

      (parts[0, head] + ["# ..."] + parts[-tail, tail]).join("\n")
    end

    def indent(text, spaces)
      pad = " " * spaces
      return "#{pad}(none)" if text.nil? || text.empty?

      text.split("\n", -1).map { |line| "#{pad}#{line}" }.join("\n")
    end
  end
end
