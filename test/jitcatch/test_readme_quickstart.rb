# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "shellwords"

# Runs the Quick starts as the README writes them, so the pasted output
# cannot drift from what jitcatch prints.
class TestReadmeQuickstart < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_quick_start_without_an_app_prints_what_the_readme_shows
    quoted = quoted_blocks("README.md", "quickstart")
    Dir.mktmpdir("jitcatch-quickstart-") do |dir|
      env = reader_shell(dir)
      run, status = Open3.capture2e(env, "bash", "-e", "-c", quoted.fetch("script"), chdir: dir)
      assert status.success?, run
      assert_equal without_commit_ids(quoted.fetch("output")), without_commit_ids(run)

      context, status = Open3.capture2e(env, "jitcatch", "context", "base", "HEAD", chdir: File.join(dir, "jitcatch-demo"))
      assert status.success?, context
      assert_includes context, quoted.fetch("context")
    end
  end

  # The sample Rails app and its bundle live outside this repository, so
  # this runs only when JITCATCH_RAILS_EXAMPLE names a copy of
  # meganemura/ruby-testing-skills' examples/rails whose bundle this Ruby has. It
  # installs this checkout as the gem, so the Gemfile step runs as written;
  # `bundle install --local` stands in for `bundle install` because the
  # gem comes from that local build.
  def test_rails_quick_start_prints_what_the_readme_shows
    example = ENV["JITCATCH_RAILS_EXAMPLE"]
    skip "set JITCATCH_RAILS_EXAMPLE to the lending-desk sample app (examples/rails in meganemura/ruby-testing-skills)" unless example

    quoted = quoted_blocks("README.md", "rails")
    Dir.mktmpdir("jitcatch-rails-") do |dir|
      shell = rails_shell(dir)
      copy = File.join(dir, "example")
      FileUtils.cp_r(File.expand_path(example), copy)
      succeed(shell, %w[sh script/setup_repo], copy)
      app = File.join(copy, "tmp", "lending-repo")
      _out, bundled = Open3.capture2e(shell, "bundle", "check", chdir: app)
      skip "the sample app's bundle is not installed for Ruby #{RUBY_VERSION}" unless bundled.success?

      env = shell.merge(installed_from_this_checkout(shell, dir))
      gemfile = File.join(app, "Gemfile")
      # The sample app pins jitcatch for its own tools, and Bundler refuses
      # a gem listed twice, so the reader's app here is one without it.
      File.write(gemfile, File.readlines(gemfile).grep_v(/^\s*gem "jitcatch"/).join + "\n#{quoted.fetch("gemfile")}")
      succeed(env, %w[bundle install --local], app)
      assert_equal quoted.fetch("pick-output"), succeed(env, ["bash", "-e", "-c", quoted.fetch("pick")], app)
      assert_equal quoted.fetch("output"), succeed(env, ["bash", "-e", "-c", quoted.fetch("script")], app)
      rerun = quoted.fetch("output")[/^    rerun: (.*)$/, 1]
      out, status = Open3.capture2e(env, "bash", "-c", rerun, chdir: app)
      refute status.success?, out
      assert_includes out, "got: :needs_senior"
    end
  end

  def test_japanese_readme_quotes_the_same_quick_starts
    english = quoted_blocks("README.md", "quickstart")
    assert_equal %w[context output script], english.keys.sort
    assert_equal english, quoted_blocks("README.ja.md", "quickstart")
    rails = quoted_blocks("README.md", "rails")
    assert_equal %w[gemfile output pick pick-output script], rails.keys.sort
    assert_equal rails, quoted_blocks("README.ja.md", "rails")
  end

  private

  # Each `<!-- PREFIX:NAME -->` marker names the fenced block after it.
  def quoted_blocks(name, prefix)
    File.read(File.join(ROOT, name), encoding: "UTF-8").scan(/^<!-- #{prefix}:([\w-]+) -->\n```\w*\n(.*?)^```$/m).to_h
  end

  def succeed(env, command, dir)
    out, status = Open3.capture2e(env, *command, chdir: dir)
    assert status.success?, "#{command.join(" ")}\n#{out}"
    out
  end

  # A shell with `jitcatch` on PATH, run by this Ruby from this checkout, and
  # a git identity of its own, so the caller's git config cannot sign or fail
  # the commits.
  def reader_shell(dir)
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    command = File.join(bin, "jitcatch")
    File.write(command, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{File.join(ROOT, "bin/jitcatch").shellescape} \"$@\"\n")
    File.chmod(0o755, command)
    git_identity(dir).merge("PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}")
  end

  # This Ruby's own `bundle` first on PATH. A bundle the suite itself runs
  # under must not reach the app's commands, so the variables `bundle exec`
  # set go back to what they were before it (its BUNDLER_ORIG_ copies).
  def rails_shell(dir)
    env = ENV.keys.grep(/\A(BUNDLE_|BUNDLER_)|\A(RUBYOPT|RUBYLIB|GEM_HOME|GEM_PATH)\z/).to_h { |key| [key, nil] }
    %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH].each do |key|
      original = ENV["BUNDLER_ORIG_#{key}"]
      env[key] = original if original && original != "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"
    end
    env.merge(git_identity(dir)).merge("PATH" => [RbConfig::CONFIG.fetch("bindir"), ENV.fetch("PATH")].join(File::PATH_SEPARATOR))
  end

  # A gem directory that holds this checkout built as the gem, in front of
  # the gems this Ruby has. GEM_HOME stays, because Bundler keeps the git
  # checkouts a committed Gemfile names (the sample app's own jitcatch
  # among them) there, and base and head run with that Gemfile.
  def installed_from_this_checkout(shell, dir)
    gems = File.join(dir, "gems")
    path, status = Open3.capture2(shell, RbConfig.ruby, "-e", "print Gem.path.join(File::PATH_SEPARATOR)")
    assert status.success?
    built = File.join(dir, "jitcatch.gem")
    out, status = Open3.capture2e(RbConfig.ruby, "-S", "gem", "build", "jitcatch.gemspec", "-o", built, chdir: ROOT)
    assert status.success?, out
    out, status = Open3.capture2e(RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document", "--install-dir", gems, built)
    assert status.success?, out
    { "GEM_PATH" => [gems, path].join(File::PATH_SEPARATOR) }
  end

  def git_identity(dir)
    global = File.join(dir, "gitconfig")
    File.write(global, "")
    {
      "GIT_CONFIG_GLOBAL" => global,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME" => "Reader",
      "GIT_AUTHOR_EMAIL" => "reader@example.com",
      "GIT_COMMITTER_NAME" => "Reader",
      "GIT_COMMITTER_EMAIL" => "reader@example.com"
    }
  end

  def without_commit_ids(text)
    text.gsub(/^(base|head) \h{40}$/, '\1 COMMIT')
  end
end
