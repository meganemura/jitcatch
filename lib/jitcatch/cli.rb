# frozen_string_literal: true

module JitCatch
  class CLI
    def self.start(argv)
      new(argv).run
    rescue UsageError => err
      warn "jitcatch: #{err.message}"
      1
    rescue GitError => err
      warn "jitcatch: #{err.message}"
      2
    end

    def initialize(argv)
      @argv = argv
    end

    def run
      if @argv.empty? || %w[-h --help help].include?(@argv.first)
        $stdout.write(help_text)
        return 0
      end

      case @argv.first
      when "context" then command_context(@argv.drop(1))
      when "run" then command_run(@argv.drop(1))
      when "assess" then command_assess(@argv.drop(1))
      else
        raise UsageError, "unknown command: #{@argv.first}\n\n#{help_text}"
      end
    end

    private

    def command_context(argv)
      opts, positional = parse_options(argv, %i[repo coverage])
      return write_help if opts[:help]
      raise UsageError, "usage: jitcatch context BASE HEAD" unless positional.size == 2

      doc = Changes.between(repo_at(opts), positional[0], positional[1], coverage: opts[:coverage])
      $stdout.write(opts[:json] ? Render.dump(Render.context_json(doc)) : Render.context_text(doc))
      0
    end

    def command_run(argv)
      opts, positional = parse_options(argv, %i[repo reruns timeout env workers])
      return write_help if opts[:help]
      raise UsageError, "usage: jitcatch run BASE HEAD TESTS_DIR" unless positional.size == 3

      raw = Runner.run(
        repo_at(opts),
        positional[0],
        positional[1],
        positional[2],
        reruns: opts.fetch(:reruns, 2),
        timeout: opts.fetch(:timeout, 10),
        env: opts.fetch(:env, []),
        workers: opts.fetch(:workers, 1)
      )
      doc = Assessor.apply(raw)
      $stdout.write(opts[:json] ? Render.dump(Render.run_json(doc)) : Render.run_text(doc))
      0
    end

    def command_assess(argv)
      opts, positional = parse_options(argv, [])
      return write_help if opts[:help]
      raise UsageError, "usage: jitcatch assess RUN.json" unless positional.size == 1

      path = positional[0]
      raise UsageError, "run json not found: #{path}" unless File.file?(path)

      raw = JSON.parse(File.read(path))
      raise UsageError, "run json must be an object" unless raw.is_a?(Hash)

      doc = Assessor.apply(raw)
      $stdout.write(opts[:json] ? Render.dump(Render.assess_json(doc)) : Render.assess_text(doc))
      0
    rescue JSON::ParserError => err
      raise UsageError, "run json is not JSON: #{err.message}"
    end

    def parse_options(argv, allowed)
      opts = {}
      positional = []
      rest = argv.dup
      while (arg = rest.shift)
        if arg == "--help" || arg == "-h"
          opts[:help] = true
        elsif arg == "--json"
          opts[:json] = true
        elsif arg.start_with?("--")
          name = arg.delete_prefix("--").tr("-", "_").to_sym
          raise UsageError, "unknown option: #{arg}" unless allowed.include?(name)

          value = rest.shift
          raise UsageError, "#{arg} requires a value" if value.nil? || value.start_with?("-")
          next (opts[:env] ||= []) << env_option(arg, value) if name == :env

          opts[name] = case name
          when :reruns then integer_option(arg, value)
          when :timeout, :workers then positive_option(arg, value)
          else value
          end
        else
          positional << arg
        end
      end
      [opts, positional]
    end

    def integer_option(flag, value)
      raise UsageError, "#{flag} requires an integer" unless value.match?(/\A\d+\z/)

      value.to_i
    end

    def positive_option(flag, value)
      number = integer_option(flag, value)
      raise UsageError, "#{flag} must be >= 1" if number < 1

      number
    end

    def env_option(flag, value)
      raise UsageError, "#{flag} needs a variable name, not #{value}" unless value.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      raise UsageError, "#{flag} cannot pass #{value}: jitcatch sets it" if Runner::RESERVED_ENV.include?(value)

      value
    end

    def repo_at(opts)
      opts[:repo] || Dir.pwd
    end

    def write_help
      $stdout.write(help_text)
      0
    end

    def help_text
      <<~HELP
        jitcatch #{VERSION}

        Deterministic Just-in-Time catching-test helper for Ruby.
        This tool never calls an LLM. An agent writes the tests and judges intent.

        Usage:
          jitcatch context [--json] [--repo DIR] [--coverage FILE] BASE HEAD
          jitcatch run [--json] [--repo DIR] [--reruns N] [--timeout SEC] [--workers N] [--env NAME]... BASE HEAD TESTS_DIR
          jitcatch assess [--json] RUN.json

        context   Short brief of changed methods, old/new source, call sites, and tests.
        run       Run each candidate file on base and head. Keep pass/fail, drop flakes.
        assess    Re-apply the rule assessor to a run JSON file.

        Exit status: 0 success, 1 usage error, 2 git error.
      HELP
    end
  end
end
