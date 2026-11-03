# frozen_string_literal: true

module JitCatch
  # How a candidate file runs and how its output reads. A `*_spec.rb` file
  # is RSpec unless it requires minitest (minitest/spec names files that way
  # too); every other file is Minitest.
  module Framework
    MINITEST_REQUIRE = /^\s*require\s*\(?\s*["']minitest/.freeze
    # A rerun command names the candidate under the directory passed to
    # `run`, which the report writes as this so it reads the same anywhere.
    TESTS = "{tests}/"
    REPORT = ".jitcatch-report.json"

    def self.for(relative, source)
      RSpec.names?(File.basename(relative)) && !source.match?(MINITEST_REQUIRE) ? RSpec : Minitest
    end

    def self.named?(relative)
      [Minitest, RSpec].any? { |framework| framework.names?(File.basename(relative)) }
    end

    module Minitest
      module_function

      BARE = /\A[\w.,:\/@\#{}=+-]+\z/

      def names?(basename)
        basename.match?(/\Atest_.+\.rb\z/) || basename.end_with?("_test.rb")
      end

      def arguments(path)
        [path, "-v", "--seed", "1"]
      end

      def parse(_report, stdout, stderr, normalizer)
        MinitestParser.parse(stdout, stderr, normalizer: normalizer)
      end

      # Minitest is a bundled gem, so under Bundler only a Gemfile that lists
      # it can load it.
      def bundle_check
        'begin; require "minitest"; rescue LoadError; $stderr.puts %(minitest is not in the bundle: add gem "minitest" to the Gemfile); exit 1; end'
      end

      def rerun(file, name, _line)
        ["ruby", "-Ilib", "-I.", "#{TESTS}#{file}", *(["-n", name] if name)].map { |part| quote(part) }.join(" ")
      end

      # A word a shell reads as written stays bare, so `{tests}/` and a
      # `Class#test` name stay readable; any other word is single-quoted.
      def quote(part)
        return part if part.match?(BARE)

        "'#{part.gsub("'", %q('\\\\''))}'"
      end
    end

    module RSpec
      module_function

      # RSpec puts lib/ of the nearest directory that holds spec/ first on
      # the load path, which under a Rails app's tmp/ is the app's lib/, not
      # the checkout's. Pinning that directory to the working directory
      # loads the checkout's lib/ in the run and in its rerun line alike.
      # RSpec cuts an object it prints to 200 characters, which can cut
      # the class and message a raise_error got out of the row.
      LAUNCH = 'require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))'

      def names?(basename)
        basename.end_with?("_spec.rb")
      end

      # `--backtrace` keeps the gem frames that tell a gem's error apart.
      # Formatters given here replace the ones a `.rspec` file names.
      def arguments(path)
        ["-e", LAUNCH, "--", "--format", "json", "--out", REPORT, "--seed", "1", "--backtrace", "--no-color", path]
      end

      def parse(report, stdout, stderr, normalizer)
        RSpecParser.parse(report, stdout, stderr, normalizer: normalizer)
      end

      def bundle_check
        'begin; require "rspec/core"; rescue LoadError; $stderr.puts %(rspec-core is not in the bundle: add gem "rspec" to the Gemfile); exit 1; end'
      end

      # The same Ruby flags and launch as the run, so the rerun loads what
      # the row loaded.
      def rerun(file, _name, line)
        ["ruby", "-Ilib", "-I.", "-e", LAUNCH, "#{TESTS}#{file}#{":#{line}" if line}"].map { |part| Minitest.quote(part) }.join(" ")
      end
    end
  end
end
