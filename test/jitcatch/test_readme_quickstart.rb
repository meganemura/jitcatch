# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "shellwords"

# Runs the Quick start as the README writes it, so the pasted output cannot
# drift from what jitcatch prints.
class TestReadmeQuickstart < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_quick_start_prints_what_the_readme_shows
    quoted = quick_start("README.md")
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

  def test_japanese_readme_quotes_the_same_quick_start
    english = quick_start("README.md")
    assert_equal %w[context output script], english.keys.sort
    assert_equal english, quick_start("README.ja.md")
  end

  private

  # Each `<!-- quickstart:NAME -->` marker names the fenced block after it.
  def quick_start(name)
    File.read(File.join(ROOT, name), encoding: "UTF-8").scan(/^<!-- quickstart:(\w+) -->\n```\w*\n(.*?)^```$/m).to_h
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
    global = File.join(dir, "gitconfig")
    File.write(global, "")
    {
      "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
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
