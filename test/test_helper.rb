# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "jitcatch"
require "fileutils"
require "open3"
require "tmpdir"
require "shellwords"
require_relative "support/repo"

module JitCatch
  module TestHelp
    def with_repo
      repo = Support::Repo.new
      yield repo
    ensure
      repo&.destroy
    end

    # Head removes the private A#helper and adds an argument to A#scale,
    # and the unchanged B still calls both: lib/b.rb:5 and lib/b.rb:9.
    def inherited_history(repo)
      repo.write("lib/a.rb", <<~RUBY)
        class A
          private

          def helper(n)
            raise ArgumentError, "n must be an Integer" unless n.is_a?(Integer)
            n * 2
          end

          def scale(n, by)
            n * by
          end
        end
      RUBY
      repo.write("lib/b.rb", <<~RUBY)
        require "a"

        class B < A
          def m(n)
            helper(n)
          end

          def k(n)
            scale(n, 3)
          end
        end
      RUBY
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/a.rb", <<~RUBY)
        class A
          private

          def scale(n, by, offset)
            n * by + offset
          end
        end
      RUBY
      repo.commit("Drop helper, offset scale.", date: "2026-02-12T00:00:00Z")
    end

    def with_env(values)
      saved = values.keys.to_h { |key| [key, ENV[key]] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved&.each { |key, value| ENV[key] = value }
    end

    def write_tests(dir, files)
      FileUtils.mkdir_p(dir)
      files.each do |name, body|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
    end
  end
end

class Minitest::Test
  include JitCatch::TestHelp
end
