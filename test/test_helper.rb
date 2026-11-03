# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "jittest"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "support/repo"

module JitTest
  module TestHelp
    def with_repo
      repo = Support::Repo.new
      yield repo
    ensure
      repo&.destroy
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
  include JitTest::TestHelp
end
