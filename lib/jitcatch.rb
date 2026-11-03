# frozen_string_literal: true

require "json"
require "rbconfig"

require_relative "jitcatch/git_repo"
require_relative "jitcatch/source_index"
require_relative "jitcatch/diff_parser"
require_relative "jitcatch/changes"
require_relative "jitcatch/failure"
require_relative "jitcatch/minitest_parser"
require_relative "jitcatch/rspec_parser"
require_relative "jitcatch/framework"
require_relative "jitcatch/assessor"
require_relative "jitcatch/runner"
require_relative "jitcatch/render"
require_relative "jitcatch/cli"

module JitCatch
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

    def dedent(text)
      return nil if text.nil?

      parts = text.split("\n", -1)
      parts.pop if parts.last&.empty?
      cut = parts.reject(&:empty?).map { |line| line[/^[ \t]*/].size }.min || 0
      parts.map { |line| line.empty? ? "" : line[cut..] }.join("\n")
    end

    # A name a test creates under the temp directory is new on every run, so
    # it would make one deterministic failure look like two different ones.
    def mask_temp_names(text, tmpdir)
      root = tmpdir.to_s.sub(%r{/+\z}, "")
      return text if root.empty?

      text.gsub(%r{(?<![\w./-])#{Regexp.escape(root)}/[^/\s"'`:]+}, "{tmp}")
    end

    def message_lines(message)
      message.to_s.lines.map(&:strip).reject(&:empty?)
    end

    def indent(text, spaces)
      pad = " " * spaces
      return "#{pad}(none)" if text.nil? || text.empty?

      text.split("\n", -1).map { |line| "#{pad}#{line}" }.join("\n")
    end
  end
end
