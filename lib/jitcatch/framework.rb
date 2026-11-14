# frozen_string_literal: true
# rbs_inline: enabled

module JitCatch
  # How a candidate file runs and how its output reads. A `*_spec.rb` file
  # is RSpec unless it requires minitest (minitest/spec names files that way
  # too); every other file is Minitest.
  module Framework
    MINITEST_REQUIRE = /^\s*require\s*\(?\s*["']minitest/.freeze #: Regexp
    REPORT = ".jitcatch-report.json" #: String

    # @rbs!
    #   # Framework::Minitest and Framework::RSpec answer the same calls.
    #   type framework = singleton(Minitest) | singleton(RSpec)

    #: (String relative, String source) -> framework
    def self.for(relative, source)
      RSpec.names?(File.basename(relative)) && !source.match?(MINITEST_REQUIRE) ? RSpec : Minitest
    end

    #: (String relative) -> bool
    def self.named?(relative)
      [Minitest, RSpec].any? { |framework| framework.names?(File.basename(relative)) }
    end

    module Minitest
      module_function

      BARE = /\A[\w.,:\/@\#{}=+-]+\z/ #: Regexp

      #: (String basename) -> bool
      def names?(basename)
        basename.match?(/\Atest_.+\.rb\z/) || basename.end_with?("_test.rb")
      end

      REPORTER = File.expand_path("minitest_report.rb", __dir__.to_s) #: String

      #: (String path) -> Array[String]
      def arguments(path)
        ["-r#{REPORTER}", path, "--seed", "1"]
      end

      #: (String? report, String stdout, String stderr, normalizer normalizer) -> doc
      def parse(report, stdout, stderr, normalizer)
        MinitestParser.parse(report, stdout, stderr, normalizer: normalizer)
      end

      LIBRARY = "minitest" #: String

      # Minitest is a bundled gem, so under Bundler only a Gemfile that lists
      # it can load it.
      #: (bool bundled) -> String
      def missing(bundled)
        bundled ? 'minitest is not in the bundle: add gem "minitest" to the Gemfile' : "minitest is not installed for this Ruby: gem install minitest"
      end

      #: (String path, String? name, Integer? _line, ?pin_root: bool, ?launcher: bool) -> String
      def rerun(path, name, _line, pin_root: true, launcher: false)
        selection = name ? ["-n", name] : [] #: Array[String]
        ["ruby", "-Ilib", "-I.", path, *selection].map { |part| quote(part) }.join(" ")
      end

      # A word a shell reads as written stays bare, so a path and a
      # `Class#test` name stay readable; any other word is single-quoted.
      #: (String part) -> String
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
      PIN_ROOT = "RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); " #: String
      LAUNCH = 'require "rspec/core"; require "rspec/support/object_formatter"; ' \
               "#{PIN_ROOT}" \
               "RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))" #: String

      #: (String basename) -> bool
      def names?(basename)
        basename.end_with?("_spec.rb")
      end

      # `--backtrace` keeps the gem frames that tell a gem's error apart.
      # Formatters given here replace the ones a `.rspec` file names.
      #: (String path) -> Array[String]
      def arguments(path)
        ["-e", LAUNCH, "--", "--format", "json", "--out", REPORT, "--seed", "1", "--backtrace", "--no-color", path]
      end

      #: (String? report, String stdout, String stderr, normalizer normalizer) -> doc
      def parse(report, stdout, stderr, normalizer)
        RSpecParser.parse(report, stdout, stderr, normalizer: normalizer)
      end

      LIBRARY = "rspec/core" #: String

      #: (bool bundled) -> String
      def missing(bundled)
        bundled ? 'rspec-core is not in the bundle: add gem "rspec" to the Gemfile' : "rspec-core is not installed for this Ruby: gem install rspec-core"
      end

      # What `rspec -r` loads to lift the cut, when head's Ruby can load it.
      LAUNCHER = "jitcatch/rspec" #: String

      # The same load path and launch as the run, so the rerun loads what
      # the row loaded. In a checkout that holds spec/ RSpec already takes
      # the working directory as its root and adds its lib/, so the line
      # needs no pin, the one part that sets rspec-core's private state, and
      # is plain `rspec` when head's Ruby loads the launcher.
      #: (String path, String? _name, Integer? line, ?pin_root: bool, ?launcher: bool) -> String
      def rerun(path, _name, line, pin_root: true, launcher: false)
        target = "#{path}#{":#{line}" if line}"
        return ["rspec", "-I.", "-r", LAUNCHER, target].map { |part| Minitest.quote(part) }.join(" ") if launcher && !pin_root

        launch = pin_root ? LAUNCH : LAUNCH.sub(PIN_ROOT, "")
        ["ruby", "-Ilib", "-I.", "-e", launch, target].map { |part| Minitest.quote(part) }.join(" ")
      end
    end
  end
end
