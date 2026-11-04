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

    # The commits only base has, which `diff BASE HEAD` undoes, and the
    # merge base `log BASE..HEAD` starts from. Nil when base is an ancestor.
    def divergence(base, head)
      return nil if empty_tree?(base)

      _stdout, _stderr, status = capture("merge-base", "--is-ancestor", "--end-of-options", base, head)
      return nil if status.success?

      count = git("rev-list", "--count", "--end-of-options", "#{head}..#{base}").strip.to_i
      fork = capture("merge-base", "--end-of-options", base, head).first.strip
      { "base_only" => count, "merge_base" => fork.empty? ? nil : fork }
    end

    Blob = Data.define(:path, :oid, :size)

    # `-z` leaves a path with a tab, a newline, or a quote unquoted too.
    def ruby_blobs(ref)
      git("ls-tree", "-r", "-l", "-z", "--end-of-options", ref).split("\0").filter_map { |entry|
        meta, path = entry.split("\t", 2)
        _mode, type, oid, size = meta.split
        Blob.new(path: path, oid: oid, size: size.to_i) if type == "blob" && path.end_with?(".rb")
      }.sort_by(&:path)
    end

    # One `cat-file` reads every blob. A `git show` per file cost one process
    # each, which was most of the time `context` took.
    def read_blobs(oids)
      return {} if oids.empty?

      stdout, stderr, status = Open3.capture3(
        "git", "--no-pager", "-C", @dir, "cat-file", "--batch",
        stdin_data: "#{oids.join("\n")}\n", binmode: true
      )
      raise GitError, "git cat-file failed: #{stderr.strip}" unless status.success?

      blobs = {}
      offset = 0
      while (newline = stdout.index("\n", offset))
        oid, _type, size = stdout.byteslice(offset, newline - offset).split
        blobs[oid] = as_utf8(stdout.byteslice(newline + 1, size.to_i))
        offset = newline + size.to_i + 2
      end
      blobs
    end

    def show(ref, path)
      stdout, _stderr, status = capture("show", "--end-of-options", "#{ref}:#{path}")
      status.success? ? stdout : nil
    end

    # The parts of the Ruby files at ref that match pattern, an extended
    # regexp. git grep exits 1 when nothing matches.
    def ruby_matches(ref, pattern)
      stdout, _stderr, status = capture("grep", "-h", "-o", "-I", "-E", "-e", pattern, ref, "--", "*.rb")
      status.success? ? stdout.lines(chomp: true) : []
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

    # git quotes a path with non-ASCII bytes by default, and a quoted path
    # names no file in `show` and matches no hunk path.
    def capture(*args, env: nil)
      command = ["git", "--no-pager", "-c", "core.quotePath=false", "-C", @dir, *args]
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
