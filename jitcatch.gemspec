# frozen_string_literal: true

require_relative "lib/jitcatch/version"

Gem::Specification.new do |spec|
  spec.name = "jitcatch"
  spec.version = JitCatch::VERSION
  spec.authors = ["meganemura"]
  spec.email = ["meganemura@users.noreply.github.com"]
  spec.summary = "Keep the Ruby tests that pass on the parent of a change and fail on the change."
  spec.description = "jitcatch runs candidate Minitest or RSpec files on two git revisions, drops flakes and other non-signals, and prints the tests that pass on the parent and fail on the change, with the changed methods each one reaches."
  spec.homepage = "https://github.com/meganemura/jitcatch"
  spec.license = "MIT"
  # test/run.rb passes on Ruby 3.3 with the prism and minitest it ships.
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").select do |path|
      path.start_with?("bin/", "lib/", "skills/") || %w[LICENSE README.md README.ja.md].include?(path)
    end
  end
  spec.bindir = "bin"
  spec.executables = ["jitcatch"]
end
