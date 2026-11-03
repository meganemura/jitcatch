# frozen_string_literal: true

require "open3"
require "fileutils"

module JitCatch
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

    # `ROOT^` names nothing in git. Reading it as the empty tree lets a
    # review of the first commit use the same BASE HEAD form as any other.
    def base_rev(ref)
      rev(ref)
    rescue GitError
      child = ref.to_s[/\A(.+?)(?:\^1?|~1?)\z/, 1]
      raise unless child && root_commit?(rev(child))

      empty_tree
    end

    def empty_tree?(sha)
      sha == empty_tree
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

    # Oldest first. %(trailers) prints the block git itself parses as trailers,
    # verbatim, so cutting it off the end of %B leaves the message without it.
    def commit_messages(base, head)
      range = empty_tree?(base) ? head : "#{base}..#{head}"
      raw = git("log", "--reverse", "--format=%B%x1f%(trailers)%x1e", "--end-of-options", range)
      raw.split("\x1e").filter_map do |record|
        message, trailers = record.split("\x1f", 2)
        next if trailers.nil?

        message = message.rstrip
        block = trailers.rstrip
        block.empty? ? message : message.delete_suffix(block)
      end
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
      status.success? ? stdout : nil
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

    def root_commit?(sha)
      git("rev-list", "--parents", "-n", "1", "--end-of-options", sha).split.size == 1
    end

    def empty_tree
      @empty_tree ||= git("hash-object", "-t", "tree", "--end-of-options", File::NULL).strip
    end

    def capture(*args, env: nil)
      command = ["git", "--no-pager", "-C", @dir, *args]
      merged = ENV.to_h.merge(env || {})
      stdout, stderr, status = Open3.capture3(merged, *command)
      [as_utf8(stdout), as_utf8(stderr), status]
    end

    # Open3 tags output with the locale's encoding, which is US-ASCII under
    # LANG=C. Paths, sources, and messages in a repository are UTF-8 bytes,
    # and a stray invalid byte must not stop a regexp match.
    def as_utf8(text)
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("?")
    end
  end
end
