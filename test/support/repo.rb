# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Support
  class Repo
    attr_reader :dir

    def initialize
      @dir = Dir.mktmpdir("jitcatch-repo-")
      git("init", "-b", "main")
      git("config", "user.email", "jittest@example.local")
      git("config", "user.name", "jittest")
      git("config", "commit.gpgsign", "false")
      git("config", "core.autocrlf", "false")
    end

    def write(path, content)
      full = File.join(@dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content.gsub("\r\n", "\n"))
    end

    def commit(message, date:)
      git("add", "-A")
      env = {
        "GIT_AUTHOR_NAME" => "jittest",
        "GIT_AUTHOR_EMAIL" => "jittest@example.local",
        "GIT_AUTHOR_DATE" => date,
        "GIT_COMMITTER_NAME" => "jittest",
        "GIT_COMMITTER_EMAIL" => "jittest@example.local",
        "GIT_COMMITTER_DATE" => date
      }
      git("commit", "-m", message, env: env)
      git("rev-parse", "HEAD").strip
    end

    def branch(name)
      git("branch", name)
    end

    def checkout(name)
      git("checkout", name)
    end

    def git(*args, env: nil)
      command = ["git", "--no-pager", "-C", @dir, *args]
      stdout, stderr, status = Open3.capture3(ENV.to_h.merge(env || {}), *command)
      return stdout if status.success?

      raise "git #{args.first} failed: #{stderr.strip}"
    end

    def destroy
      return unless @dir && File.directory?(@dir)

      FileUtils.remove_entry(@dir)
    end
  end
end
