# frozen_string_literal: true
# rbs_inline: enabled

require "open3"
require "fileutils"

module JitCatch
  # Thin git wrapper. Every invocation is an argv array, never a shell.
  # `dir` is the directory the reader works in, which can be a directory
  # inside the repository, as a gem's `ruby/` is in a monorepo. git runs
  # from the repository's top, so every path it prints or takes is from
  # there, the way the diff names them.
  class GitRepo
    attr_reader :dir #: String

    # @rbs @prefix: String?
    # @rbs @toplevel: String?
    # @rbs @empty_tree: String?

    #: (String path) -> void
    def initialize(path)
      @dir = File.expand_path(path)
      raise UsageError, "not a directory: #{path}" unless File.directory?(@dir)
    end

    # The path of `dir` from the repository's top, with a trailing slash,
    # as `ruby/`, or "" at the top.
    #: () -> String
    def prefix
      locate
      @prefix #: String
    end

    # The top of the repository, as git prints it.
    #: () -> String
    def toplevel
      locate
      @toplevel #: String
    end

    #: (String ref) -> String
    def rev(ref)
      git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
    end

    # `ROOT^` names nothing in git. Reading it as the empty tree lets a
    # review of the first commit use the same BASE HEAD form as any other.
    #: (String ref) -> String
    def base_rev(ref)
      rev(ref)
    rescue GitError
      child = ref.to_s[/\A(.+?)(?:\^1?|~1?)\z/, 1]
      raise unless child && root_commit?(rev(child))

      empty_tree
    end

    #: (String sha) -> bool
    def empty_tree?(sha)
      sha == empty_tree
    end

    #: (String base, String head) -> String
    def diff(base, head)
      git(
        "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-renames",
        "--end-of-options", base, head
      )
    end

    #: (String base, String head) -> String
    def name_status(base, head)
      git("diff", "--name-status", "--no-renames", "--end-of-options", base, head)
    end

    # Oldest first. %(trailers) prints the block git itself parses as trailers,
    # verbatim, so cutting it off the end of %B leaves the message without it.
    #: (String base, String head) -> Array[String]
    def commit_messages(base, head)
      range = empty_tree?(base) ? head : "#{base}..#{head}"
      raw = git("log", "--reverse", "--format=%B%x1f%(trailers)%x1e", "--end-of-options", range)
      raw.split("\x1e").filter_map do |record|
        message, trailers = record.split("\x1f", 2) #: [String, String?]
        next if trailers.nil?

        message = message.rstrip
        block = trailers.rstrip
        block.empty? ? message : message.delete_suffix(block)
      end
    end

    # The commits only base has, which `diff BASE HEAD` undoes, and the
    # merge base `log BASE..HEAD` starts from. Nil when base is an ancestor.
    #: (String base, String head) -> doc?
    def divergence(base, head)
      return nil if empty_tree?(base)

      _stdout, _stderr, status = capture("merge-base", "--is-ancestor", "--end-of-options", base, head)
      return nil if status.success?

      count = git("rev-list", "--count", "--end-of-options", "#{head}..#{base}").strip.to_i
      fork = capture("merge-base", "--end-of-options", base, head).first.strip
      { "base_only" => count, "merge_base" => fork.empty? ? nil : fork }
    end

    Blob = Data.define(
      :path, #: String
      :oid, #: String
      :size #: Integer
    )

    # A symlink is a blob that holds the path it points at, not Ruby. Its
    # target is listed on its own when the repository holds it.
    SYMLINK_MODE = "120000" #: String

    # The Ruby files and the ERB templates at ref.
    # `-z` leaves a path with a tab, a newline, or a quote unquoted too.
    #: (String ref) -> Array[Blob]
    def source_blobs(ref)
      git("ls-tree", "-r", "-l", "-z", "--end-of-options", ref).split("\0").filter_map { |entry|
        meta, path = entry.split("\t", 2) #: [String, String]
        mode, type, oid, size = meta.split #: [String, String, String, String]
        next unless type == "blob" && mode != SYMLINK_MODE && (path.end_with?(".rb") || Template.template?(path) || SourceIndex.script_path?(path))

        Blob.new(path: path, oid: oid, size: size.to_i)
      }.sort_by(&:path)
    end

    # One `cat-file` reads every blob. A `git show` per file cost one process
    # each, which was most of the time `context` took.
    # Each blob's text, by its oid.
    #: (Array[String] oids) -> Hash[String, String]
    def read_blobs(oids)
      return {} if oids.empty?

      stdout, stderr, status = Open3.capture3(
        "git", "--no-pager", "-C", @dir, "cat-file", "--batch",
        stdin_data: "#{oids.join("\n")}\n", binmode: true
      )
      raise GitError, "git cat-file failed: #{stderr.strip}" unless status.success?

      blobs = {} #: Hash[String, String]
      offset = 0
      while (newline = stdout.index("\n", offset))
        header = stdout.byteslice(offset, newline - offset) #: String
        oid, _type, size = header.split #: [String, String, String]
        body = stdout.byteslice(newline + 1, size.to_i) #: String
        blobs[oid] = as_utf8(body)
        offset = newline + size.to_i + 2
      end
      blobs
    end

    #: (String ref, String path) -> String?
    def show(ref, path)
      stdout, _stderr, status = capture("show", "--end-of-options", "#{ref}:#{path}")
      status.success? ? stdout : nil
    end

    # The parts of the Ruby files at ref that match pattern, an extended
    # regexp, one per line. git grep exits 1 when nothing matches.
    #: (String ref, String pattern) -> String
    def ruby_matches(ref, pattern)
      stdout, _stderr, status = capture("grep", "-h", "-o", "-I", "-E", "-e", pattern, ref, "--", "*.rb")
      status.success? ? stdout : ""
    end

    #: (String path, String sha) -> String
    def worktree_add(path, sha)
      git("worktree", "add", "--detach", "--quiet", "--end-of-options", path, sha)
    end

    #: (String path) -> void
    def worktree_remove(path)
      return unless File.directory?(path)

      _stdout, _stderr, status = capture("worktree", "remove", "--force", "--end-of-options", path)
      FileUtils.remove_entry(path) if !status.success? && File.directory?(path)
    end

    #: () -> [String, String, Process::Status]
    def worktree_prune
      capture("worktree", "prune")
    end

    #: () -> String
    def worktree_list
      git("worktree", "list", "--porcelain")
    end

    # Its stdout, or a GitError with what it printed.
    #: (*String args, ?env: Hash[String, String?]?) -> String
    def git(*args, env: nil)
      stdout, stderr, status = capture(*args, env: env)
      return stdout if status.success?

      detail = stderr.strip
      detail = stdout.strip if detail.empty?
      raise GitError, "git #{args.first} failed: #{detail}"
    end

    private

    #: (String sha) -> bool
    def root_commit?(sha)
      git("rev-list", "--parents", "-n", "1", "--end-of-options", sha).split.size == 1
    end

    #: () -> String
    def empty_tree
      @empty_tree ||= git("hash-object", "-t", "tree", "--end-of-options", File::NULL).strip
    end

    # git quotes a path with non-ASCII bytes by default, and a quoted path
    # names no file in `show` and matches no hunk path.
    #: (*String args, ?env: Hash[String, String?]?) -> [String, String, Process::Status]
    def capture(*args, env: nil)
      capture_in(toplevel, *args, env: env)
    end

    # From a directory inside the repository, `ls-tree` and `grep` list only
    # that directory, by paths from it, which name no file of the diff.
    #: () -> void
    def locate
      return if @toplevel

      stdout, stderr, status = capture_in(@dir, "rev-parse", "--show-toplevel", "--show-prefix")
      raise GitError, "git rev-parse failed: #{stderr.strip}" unless status.success?

      top, prefix = stdout.lines.map(&:chomp)
      @prefix = prefix.to_s
      @toplevel = top
    end

    #: (String dir, *String args, ?env: Hash[String, String?]?) -> [String, String, Process::Status]
    def capture_in(dir, *args, env: nil)
      command = ["git", "--no-pager", "-c", "core.quotePath=false", "-C", dir, *args]
      merged = ENV.to_h.merge(env || {})
      stdout, stderr, status = Open3.capture3(merged, *command)
      [as_utf8(stdout), as_utf8(stderr), status]
    end

    # Open3 tags output with the locale's encoding, which is US-ASCII under
    # LANG=C. Paths, sources, and messages in a repository are UTF-8 bytes,
    # and a stray invalid byte must not stop a regexp match.
    #: (String text) -> String
    def as_utf8(text)
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("?")
    end
  end
end
