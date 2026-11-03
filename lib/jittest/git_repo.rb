# frozen_string_literal: true

require "open3"
require "fileutils"

module JitTest
  # Thin git wrapper. Every invocation is an argv array, never a shell.
  class GitRepo
    attr_reader :dir

    def initialize(path)
      @dir = File.expand_path(path)
      raise UsageError, "not a directory: #{path}" unless File.directory?(@dir)
    end

    def rev(ref)
      git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
    end

    def diff(base, head)
      git(
        "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-renames",
        "--end-of-options", base, head
      )
    end

    def name_status(base, head)
      git("diff", "--name-status", "--no-renames", "--end-of-options", base, head)
    end

    def log_messages(base, head)
      git("log", "--reverse", "--format=%B%x1e", "--end-of-options", "#{base}..#{head}")
    end

    def ruby_files(ref)
      git("ls-tree", "-r", "--name-only", "--end-of-options", ref)
        .lines
        .map(&:strip)
        .select { |path| path.end_with?(".rb") }
        .sort
    end

    def show(ref, path)
      stdout, _stderr, status = capture("show", "--end-of-options", "#{ref}:#{path}")
      return nil unless status.success?

      stdout.force_encoding(Encoding::UTF_8)
      stdout.valid_encoding? ? stdout : stdout.scrub("?")
    end

    def worktree_add(path, sha)
      git("worktree", "add", "--detach", "--quiet", "--end-of-options", path, sha)
    end

    def worktree_remove(path)
      return unless File.directory?(path)

      _stdout, _stderr, status = capture("worktree", "remove", "--force", "--end-of-options", path)
      FileUtils.remove_entry(path) if !status.success? && File.directory?(path)
    end

    def worktree_prune
      capture("worktree", "prune")
    end

    def worktree_list
      git("worktree", "list", "--porcelain")
    end

    def git(*args, env: nil)
      stdout, stderr, status = capture(*args, env: env)
      return stdout if status.success?

      detail = stderr.strip
      detail = stdout.strip if detail.empty?
      raise GitError, "git #{args.first} failed: #{detail}"
    end

    private

    def capture(*args, env: nil)
      command = ["git", "--no-pager", "-C", @dir, *args]
      merged = ENV.to_h.merge(env || {})
      Open3.capture3(merged, *command)
    end
  end
end
