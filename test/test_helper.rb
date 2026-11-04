# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

unless defined?(Bundler)
  # `require` loads the newest gem installed, so a Ruby with newer prism and
  # minitest gems (minitest 6 needs prism 1.5) hides what a bare Ruby does.
  # The oldest installed version of each is the one that ships with Ruby.
  %w[prism minitest].each { |name| gem name, Gem::Specification.find_all_by_name(name).min_by(&:version).version.to_s }
  # minitest 5 loads the plugins of every installed minitest, and minitest 6's
  # plugins load minitest 6 over it, which drops every test defined so far.
  ENV["MT_NO_PLUGINS"] = "1"
end

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

    # Head changes three methods named `parse` and the `Failure.result` one
    # of them calls, so a bare name cannot tell the test's callee apart.
    def same_named_history(repo)
      sources = lambda do |mark|
        repo.write("lib/a.rb", <<~RUBY)
          module Failure
            def self.result(text) = text.to_s + "#{mark}"
          end

          class Index
            def self.parse(text) = text.to_s + "#{mark}"
          end

          class Report
            def self.parse(text) = Failure.result(text) + "#{mark}"
          end

          class Log
            def self.parse(text) = text.to_s + "#{mark}"
          end
        RUBY
      end
      sources.call("")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      sources.call("!")
      repo.commit("Mark every parse.", date: "2026-02-12T00:00:00Z")
    end

    # Head changes the constructor of Loan, an ActiveRecord model that a
    # factory builds. ActiveRecord and FactoryBot are stand-ins a candidate
    # loads from RECORD_STANDINS, outside the history, so the index sees
    # neither one's `create`.
    def record_history(repo, factories: "FactoryBot.define do\n  factory :loan do\n  end\nend\n")
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      loan = lambda do |mark|
        <<~RUBY
          require "application_record"

          class Loan < ApplicationRecord
            attr_reader :approved_by

            def initialize(attributes = nil)
              @approved_by = "#{mark}"
            end
          end
        RUBY
      end
      repo.write("lib/loan.rb", loan.call("nobody"))
      repo.write("spec/factories/loans.rb", factories)
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/loan.rb", loan.call("pending"))
      repo.commit("Mark a new loan as pending.", date: "2026-02-12T00:00:00Z")
    end

    # Head changes three methods of Loan that ActiveRecord runs through a
    # declaration: an `after_save` callback, an `if:` condition of a
    # validation, and a method a `before_destroy` callback calls. Notes
    # declares an `after_save` too, but is not a model.
    def callback_history(repo)
      repo.write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
      loan = lambda do |step|
        <<~RUBY
          require "application_record"

          class Loan < ApplicationRecord
            attr_reader :saves

            validates :amount, presence: true, if: :checked?
            after_save :count_save
            before_destroy :archive

            def count_save
              @saves = (@saves || 0) + #{step}
            end

            def checked?
              #{step} > 0
            end

            def archive
              archived_mark
            end

            def archived_mark
              #{step}
            end
          end
        RUBY
      end
      notes = ->(step) { "class Notes\n  after_save :tidy\n\n  def tidy\n    #{step}\n  end\nend\n" }
      repo.write("lib/loan.rb", loan.call(1))
      repo.write("lib/notes.rb", notes.call(1))
      repo.write("spec/factories/loans.rb", "FactoryBot.define do\n  factory :loan do\n  end\nend\n")
      repo.commit("base", date: "2026-02-11T00:00:00Z")
      repo.branch("base")
      repo.write("lib/loan.rb", loan.call(2))
      repo.write("lib/notes.rb", notes.call(2))
      repo.commit("Count each save twice.", date: "2026-02-12T00:00:00Z")
    end

    # The stand-in runs each `after_save` callback on `save!`, as
    # ActiveRecord does, and FactoryBot's `create` saves what it builds.
    # It runs no validation, so the test reads which changed methods a save
    # can reach, not which one it did.
    RECORD_STANDINS = <<~RUBY
      module ActiveRecord
        class Base
          def self.create!(attributes = nil) = new(attributes).tap(&:save!)
          def initialize(attributes = nil) = nil
          def self.after_save(*names) = (@after_save ||= []).concat(names)
          def self.validates(*) = nil
          def self.before_destroy(*) = nil

          def save!
            Array(self.class.instance_variable_get(:@after_save)).each { |name| send(name) }
            true
          end
        end
      end

      module Factories
        def create(name) = Object.const_get(name.to_s.capitalize).new.tap(&:save!)
      end
    RUBY

    def with_env(values)
      saved = values.keys.to_h { |key| [key, ENV[key]] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved&.each { |key, value| ENV[key] = value }
    end

    # A failed bundle names the BUNDLE_ settings the caller has and did not
    # pass, so a test that reads that message starts with none.
    def without_bundler_settings(&block)
      with_env(ENV.keys.grep(/\ABUNDLE_/).to_h { |name| [name, nil] }, &block)
    end

    # Each side the run stopped on, mapped to its stderr tail and the
    # Bundler settings it did not get.
    def setup_failures(repo, tests, env: [])
      err = assert_raises(JitCatch::EnvironmentError) { JitCatch::Runner.run(repo.dir, "base", "HEAD", tests, reruns: 0, env: env) }
      err.doc["setup_failed"].to_h { |failure| [failure["side"], failure.values_at("stderr", "not_passed")] }
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
