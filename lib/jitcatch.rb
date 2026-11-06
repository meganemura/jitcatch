# frozen_string_literal: true

require "json"
require "rbconfig"

require_relative "jitcatch/version"
require_relative "jitcatch/git_repo"
require_relative "jitcatch/source_index"
require_relative "jitcatch/factories"
require_relative "jitcatch/inflections"
require_relative "jitcatch/routes"
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
  class Error < StandardError; end
  class UsageError < Error; end
  class GitError < Error; end

  # A side whose setup check failed would turn every candidate into a load
  # error, which reads like a test finding, so the run stops instead.
  # `doc` is the document the CLI prints.
  class EnvironmentError < Error
    attr_reader :doc

    def initialize(doc)
      @doc = doc
      super("setup failed on #{doc["setup_failed"].map { |failure| failure["side"] }.join(" and ")}")
    end
  end

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

    # An object's inspect (`#<Class:0x00007f...>`) names its address, which
    # is new on every run.
    def mask_addresses(text)
      text.gsub(/\b0x\h{6,}\b/, "0x{address}")
    end

    # A record prints the time it was saved (`created_at: "2026-11-04
    # 19:02:03.212197000 +0000"`), which is new on every run. A date alone
    # stays: a test can claim one.
    def mask_times(text)
      text.gsub(/(?<!\d)\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d+)?(?: ?(?:[+-]\d\d:?\d\d|UTC)|Z)?/, "{time}")
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
