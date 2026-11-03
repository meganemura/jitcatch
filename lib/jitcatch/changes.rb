# frozen_string_literal: true

module JitCatch
  # Builds the deterministic change document shared by `context` and `run`.
  class Changes
    MAX_BLOB = 200_000
    CALLSITE_CAP = 8
    REACHABLE_CAP = 8
    TEST_CAP = 5
    ENTRY_CAP = 12
    UPSTREAM_DEPTH = 4

    def self.between(repo, base_ref, head_ref, coverage: nil)
      new(repo, base_ref, head_ref, coverage: coverage).build
    end

    def initialize(repo, base_ref, head_ref, coverage: nil)
      @git = repo.is_a?(GitRepo) ? repo : GitRepo.new(repo)
      @base_ref = base_ref
      @head_ref = head_ref
      @coverage = coverage.nil? ? nil : CoverageFile.load(coverage)
      @texts = {}
      @parsed = {}
    end

    def build
      base = @git.base_rev(@base_ref)
      head = @git.rev(@head_ref)
      files = DiffParser.name_status(@git.name_status(base, head))
      hunks = index_hunks(DiffParser.parse(@git.diff(base, head)))
      base_idx = index_ref(base, "base")
      head_idx = index_ref(head, "head")
      methods = changed_methods(base_idx, head_idx, hunks)
      constants = changed_constants(base_idx, head_idx, hunks, methods)
      attach_affected(methods, constants, base_idx, head_idx)
      assign_ids(methods, "m")
      assign_ids(constants, "k")
      link_constants(methods, constants)
      head_edges = edges_for(head_idx)
      base_edges = edges_for(base_idx)
      decorate_calls(methods, head_edges, base_edges)
      decorate_tests(methods, base_idx, head_idx)
      entrypoints = entrypoints_for(methods, head_idx, base_idx)

      {
        "version" => VERSION,
        "base" => base,
        "head" => head,
        "existing_tests_via" => @coverage ? "coverage" : "grep",
        "warnings" => warnings(base, head),
        "intent" => intent_lines(base, head),
        "files" => files,
        "dependencies" => dependencies(base, head),
        "parse_errors" => (base_idx["errors"] + head_idx["errors"]).sort_by { |err| [err["ref"], err["file"], err["message"]] },
        "constants" => constants.map { |item| constant_hash(item) },
        "methods" => methods.map { |item| method_hash(item) },
        "entrypoints" => entrypoints
      }
    end

    private

    def warnings(base, head)
      divergence = @git.divergence(base, head)
      return [] unless divergence

      count = divergence["base_only"]
      commits = count == 1 ? "1 commit" : "#{count} commits"
      fix = if divergence["merge_base"]
        "Pass `git merge-base BASE HEAD` (#{divergence["merge_base"][0, 12]}) as BASE to review head's commits alone."
      else
        "The two revisions share no history."
      end
      ["base is not an ancestor of head: the diff also undoes the #{commits} only base has. #{fix}"]
    end

    # Each spec line in a lockfile is four spaces, a name, and the version
    # in parentheses. A gem locked for several platforms has several lines.
    def dependencies(base, head)
      old = locked_versions(base)
      new = locked_versions(head)
      (old.keys | new.keys).sort.filter_map do |gem|
        next if old[gem] == new[gem]

        { "gem" => gem, "old" => old[gem], "new" => new[gem] }
      end
    end

    def locked_versions(sha)
      @git.show(sha, "Gemfile.lock").to_s.scan(/^    (\S+) \(([^)]+)\)$/)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).uniq.sort.join(" ") }
    end

    def index_hunks(files)
      map = {}
      files.each do |file|
        path = file["new_path"] || file["old_path"]
        next unless path&.end_with?(".rb")

        map[path] = file
      end
      map
    end

    def index_ref(sha, label)
      methods = []
      constants = []
      namespaces = []
      calls = []
      private_constants = []
      errors = []
      sources = {}
      listed = @git.ruby_blobs(sha).select { |blob| blob.size <= MAX_BLOB }
      @texts.merge!(@git.read_blobs(listed.map(&:oid).uniq - @texts.keys))
      listed.each do |blob|
        file = blob.path
        sources[file] = @texts.fetch(blob.oid)
        # A file both sides share is parsed once.
        index = (@parsed[[file, blob.oid]] ||= SourceIndex.parse(sources[file], file: file))
        if index.parse_error
          errors << { "ref" => label, "file" => file, "message" => index.parse_error }
          next
        end
        methods.concat(index.methods)
        constants.concat(index.constants)
        namespaces.concat(index.namespaces)
        calls.concat(index.calls)
        private_constants.concat(index.private_constants)
      end
      methods = SourceIndex.hide_private_constants(methods, private_constants.uniq)
      { "methods" => methods, "constants" => constants, "namespaces" => namespaces, "calls" => calls, "errors" => errors, "sources" => sources }
    end

    def changed_methods(base_idx, head_idx, hunks)
      old_map = index_by(base_idx["methods"])
      new_map = index_by(head_idx["methods"])
      found = []
      (old_map.keys | new_map.keys).each do |key|
        old_m = old_map[key]
        new_m = new_map[key]
        file = (new_m || old_m).file
        file_hunks = hunks[file]
        next if file_hunks.nil? || test_file?(file)

        old_hit = old_m && DiffParser.overlaps?(old_m.start_line, old_m.end_line, file_hunks["hunks"], "old")
        new_hit = new_m && DiffParser.overlaps?(new_m.start_line, new_m.end_line, file_hunks["hunks"], "new")
        source_diff = norm(old_m&.source) != norm(new_m&.source)
        params_diff = old_m&.params.to_s != new_m&.params.to_s
        # A macro line holds several names, so a hunk on it says nothing about one name.
        line_hit = (old_hit || new_hit) && (old_m || new_m).macro.nil?
        visibility_diff = old_m && new_m && old_m.visibility != new_m.visibility
        change = if old_m && new_m
          next unless line_hit || source_diff || params_diff || visibility_diff

          "modified"
        elsif new_m && (new_hit || file_hunks["old_path"].nil?)
          "added"
        elsif old_m && (old_hit || file_hunks["new_path"].nil?)
          "removed"
        end
        next unless change

        found << {
          "change" => change,
          "old" => old_m,
          "new" => new_m,
          "via_constant" => nil
        }
      end
      found
    end

    def changed_constants(base_idx, head_idx, hunks, _methods)
      old_map = index_by(base_idx["constants"])
      new_map = index_by(head_idx["constants"])
      found = []
      (old_map.keys | new_map.keys).each do |key|
        old_c = old_map[key]
        new_c = new_map[key]
        file = (new_c || old_c).file
        file_hunks = hunks[file]
        next if file_hunks.nil? || test_file?(file)

        old_hit = old_c && DiffParser.overlaps?(old_c.start_line, old_c.end_line, file_hunks["hunks"], "old")
        new_hit = new_c && DiffParser.overlaps?(new_c.start_line, new_c.end_line, file_hunks["hunks"], "new")
        source_diff = norm(old_c&.source) != norm(new_c&.source)
        change = if old_c && new_c
          next unless old_hit || new_hit || source_diff

          "modified"
        elsif new_c && (new_hit || file_hunks["old_path"].nil?)
          "added"
        elsif old_c && (old_hit || file_hunks["new_path"].nil?)
          "removed"
        end
        next unless change

        found << { "change" => change, "old" => old_c, "new" => new_c, "readers" => [] }
      end
      found + changed_namespaces(base_idx, head_idx, hunks)
    end

    # A class or module counts only when the other side defines it nowhere,
    # so a file that reopens an existing namespace adds nothing. Its body
    # changes show up as the methods and constants inside it.
    def changed_namespaces(base_idx, head_idx, hunks)
      old_names = base_idx["namespaces"].map(&:qualified)
      new_names = head_idx["namespaces"].map(&:qualified)
      removed = base_idx["namespaces"].reject { |node| new_names.include?(node.qualified) }
      added = head_idx["namespaces"].reject { |node| old_names.include?(node.qualified) }
      found = removed.uniq(&:qualified).filter_map { |node|
        { "change" => "removed", "old" => node, "new" => nil, "readers" => [], "namespace" => true } if hunks[node.file] && !test_file?(node.file)
      }
      found + added.uniq(&:qualified).filter_map { |node|
        { "change" => "added", "old" => nil, "new" => node, "readers" => [], "namespace" => true } if hunks[node.file] && !test_file?(node.file)
      }
    end

    def attach_affected(methods, constants, base_idx, head_idx)
      return if constants.empty?

      known = methods.to_h { |item| [identity(item["new"] || item["old"]), item] }
      constants.each do |const|
        next if const["namespace"]

        bare = (const["new"] || const["old"]).bare_name
        pattern = /\b#{Regexp.escape(bare)}\b/
        head_idx["methods"].each do |method|
          next if test_file?(method.file)
          next unless method.source.match?(pattern)

          key = identity(method)
          next if known[key]

          old_m = base_idx["methods"].find { |item| identity(item) == key }
          next unless old_m

          item = { "change" => "affected", "old" => old_m, "new" => method, "via_constant" => nil }
          methods << item
          known[key] = item
        end
      end
    end

    def link_constants(methods, constants)
      constants.each do |const|
        bare = (const["new"] || const["old"]).bare_name
        pattern = /\b#{Regexp.escape(bare)}\b/
        const["readers"] = methods.filter_map { |method|
          sources = [method["old"]&.source, method["new"]&.source].compact
          method["id"] if sources.any? { |source| source.match?(pattern) }
        }.uniq.sort
      end
      methods.each do |method|
        next unless method["change"] == "affected"

        related = constants.select { |const| const["readers"].include?(method["id"]) }
        method["via_constant"] = related.map { |const| const["id"] }.min
      end
    end

    def decorate_calls(methods, head_edges, base_edges)
      methods.each do |method|
        node = method["new"] || method["old"]
        edges = method["change"] == "removed" ? base_edges : head_edges
        direct = edges.select { |edge| edge["to"] == node.qualified }
        method["callsites"] = direct.first(CALLSITE_CAP).map { |edge|
          { "file" => edge["file"], "line" => edge["line"], "enclosing" => edge["from"] }
        }
        method["callsites_omitted"] = [direct.size - CALLSITE_CAP, 0].max
        method["reachable_from"] = upstream(node.qualified, edges)
      end
    end

    def decorate_tests(methods, base_idx, head_idx)
      test_sources = test_sources_for(base_idx, head_idx)
      public_names = (base_idx["methods"] + head_idx["methods"]).filter_map { |node| [node.qualified, true] if node.visibility == "public" }.to_h
      methods.each do |method|
        node = method["new"] || method["old"]
        method["existing_tests"] = if @coverage
          coverage_hits(method)
        else
          grep_hits(test_sources, node.bare_name)
        end
        method["entry_point_tests"] = if @coverage || !method["existing_tests"].empty?
          []
        else
          entry_point_hits(test_sources, method["reachable_from"].select { |name| public_names.key?(name) })
        end
      end
    end

    # A file counts when it names the entry point's class as a value (not as a
    # namespace, so `Minitest::Test` does not match a `Minitest` class) and
    # calls a method of the entry point's name. A bare-name grep alone matched
    # unrelated tests for common names such as build, run, and parse.
    def entry_point_hits(test_sources, entry_points)
      found = Hash.new { |hash, file| hash[file] = [] }
      entry_points.each do |name|
        qualifier, _sep, bare = SourceIndex.split_qualified(name)
        owner = qualifier.split("::").last
        call = /\.#{Regexp.escape(bare)}\b/
        named = owner && /\b#{Regexp.escape(owner)}\b(?!::)/
        test_sources.each do |file, source|
          found[file] << name if source.match?(call) && (named.nil? || source.match?(named))
        end
      end
      found.keys.sort.first(TEST_CAP).map { |file| { "file" => file, "entry_points" => found[file].sort } }
    end

    def coverage_hits(method)
      node = method["new"] || method["old"]
      start_line = node.start_line
      end_line = node.end_line
      @coverage.filter_map { |test|
        lines = test.dig("lines", node.file)
        next unless lines.is_a?(Array)
        next unless lines.any? { |line| line.is_a?(Integer) && line >= start_line && line <= end_line }

        { "file" => test["file"].to_s, "test" => test["id"].to_s, "via" => "coverage" }
      }.sort_by { |hit| [hit["file"], hit["test"]] }.first(TEST_CAP)
    end

    def grep_hits(test_sources, bare)
      return [] if bare.nil? || bare.length < 3

      pattern = /\b#{Regexp.escape(bare)}\b/
      test_sources.filter_map { |file, source|
        next unless source.match?(pattern)

        { "file" => file, "via" => "grep" }
      }.sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    def test_sources_for(base_idx, head_idx)
      paths = (base_idx["sources"].keys | head_idx["sources"].keys).select { |path| test_file?(path) }.sort
      paths.to_h { |path| [path, head_idx["sources"][path] || base_idx["sources"][path]] }
    end

    def test_file?(path)
      base = File.basename(path)
      return false unless base.end_with?(".rb")
      return true if base.start_with?("test_") || base.end_with?("_test.rb")

      parts = path.split("/")
      parts.include?("test") || parts.include?("spec")
    end

    def entrypoints_for(methods, head_idx, base_idx)
      classes = methods.map { |method| (method["new"] || method["old"]).qualifier }.uniq.sort
      classes.filter_map do |qualifier|
        next if qualifier.empty?

        pool = public_methods_of(head_idx, qualifier)
        pool = public_methods_of(base_idx, qualifier) if pool.empty?
        changed = methods.to_h { |method| [(method["new"] || method["old"]).qualified, method["change"]] }
        constructor = "#{qualifier}#initialize"
        names = pool.map(&:qualified) - [constructor]
        listed = names.map { |name| { "name" => name, "role" => changed[name] || "unchanged" } }
        if [head_idx, base_idx].any? { |idx| idx["methods"].any? { |method| method.qualified == constructor } }
          # A test builds the object with `.new`, which runs `initialize`.
          listed << { "name" => "#{qualifier}.new", "role" => changed[constructor] || "unchanged" }
        end
        listed = listed.sort_by { |item| [item["role"] == "unchanged" ? 1 : 0, item["name"].end_with?(".new") ? 0 : 1, item["name"]] }
        next if listed.empty?

        { "class" => qualifier, "methods" => listed.first(ENTRY_CAP) }
      end
    end

    def public_methods_of(idx, qualifier)
      idx["methods"].select { |method| method.qualifier == qualifier && method.visibility == "public" && !test_file?(method.file) }
    end

    def edges_for(idx)
      methods = idx["methods"]
      by_class = methods.group_by { |method| [method.qualifier, method.bare_name] }
      by_bare = methods.group_by(&:bare_name)
      qualifiers = methods.group_by(&:qualifier)
      edges = []
      idx["calls"].each do |call|
        next if call.enclosing.nil? || test_file?(call.file)

        target = call_target(call, by_class, by_bare, qualifiers)
        next if target.nil? || target.qualified == call.enclosing

        edges << { "from" => call.enclosing, "to" => target.qualified, "file" => call.file, "line" => call.line }
      end
      edges.uniq { |edge| [edge["from"], edge["to"], edge["file"], edge["line"]] }
        .sort_by { |edge| [edge["file"], edge["line"], edge["from"], edge["to"]] }
    end

    # A call on a receiver the source does not name gets no edge: a bare
    # name alone would send `line.strip` to any indexed `strip`. An implicit
    # `self` call still falls back to a unique bare name, for methods a class
    # gets from a module or a superclass; from an instance method, only to
    # an instance method, since no mixin turns a class method into one.
    def call_target(call, by_class, by_bare, qualifiers)
      qualifier, sep, _bare = SourceIndex.split_qualified(call.enclosing)
      receiver = call.receiver
      case receiver.kind
      when "self"
        same = by_class[[qualifier, call.bare_name]] || []
        instance = same.select { |method| method.kind == "instance" }
        if instance.size == 1
          instance.first
        elsif same.size == 1
          same.first
        else
          inherited = (by_bare[call.bare_name] || []).select { |method| sep == "." || method.kind == "instance" }
          inherited.first if inherited.size == 1
        end
      when "singleton", "instance"
        owner = receiver.const.nil? ? qualifier : resolve_constant(receiver.const, qualifier, qualifiers)
        found = (by_class[[owner, call.bare_name]] || []).select { |method| method.kind == receiver.kind }
        found.first if found.size == 1
      end
    end

    # Ruby looks a constant up from the innermost enclosing namespace out.
    def resolve_constant(const, qualifier, qualifiers)
      parts = qualifier.split("::")
      parts.size.downto(0).map { |n| [*parts.first(n), const].join("::") }.find { |name| qualifiers.key?(name) }
    end

    # The cap keeps the nearest callers; the kept names print sorted.
    def upstream(qualified, edges)
      reverse = Hash.new { |hash, key| hash[key] = [] }
      edges.each { |edge| reverse[edge["to"]] << edge["from"] }
      depths = {}
      queue = reverse[qualified].uniq.map { |name| [name, 1] }
      until queue.empty?
        name, depth = queue.shift
        next if name == qualified || depths.key?(name)

        depths[name] = depth
        next if depth >= UPSTREAM_DEPTH

        reverse[name].each { |parent| queue << [parent, depth + 1] unless depths.key?(parent) }
      end
      depths.sort_by { |name, depth| [depth, name] }.first(REACHABLE_CAP).map(&:first).sort
    end

    def intent_lines(base, head)
      messages = @git.commit_messages(base, head).filter_map do |message|
        lines = message.lines.map(&:strip).reject(&:empty?)
        lines.empty? ? nil : lines
      end

      messages.flat_map.with_index { |lines, index| index.zero? ? lines : ["---", *lines] }
    end

    def method_hash(item)
      node = item["new"] || item["old"]
      old_node = item["old"]
      new_node = item["new"]
      {
        "id" => item["id"],
        "change" => item["change"],
        "file" => node.file,
        "name" => node.qualified,
        "bare_name" => node.bare_name,
        "kind" => node.kind,
        "visibility" => (new_node || old_node).visibility,
        "signature" => signature_of(item["change"], old_node, new_node),
        "start_line" => (new_node || old_node).start_line,
        "end_line" => (new_node || old_node).end_line,
        "old_start" => old_node&.start_line,
        "old_end" => old_node&.end_line,
        "new_start" => new_node&.start_line,
        "new_end" => new_node&.end_line,
        "old_source" => cap(Text.dedent(old_node&.source)),
        "new_source" => cap(Text.dedent(new_node&.source)),
        "callsites" => item["callsites"],
        "callsites_omitted" => item["callsites_omitted"],
        "reachable_from" => item["reachable_from"],
        "existing_tests" => item["existing_tests"],
        "entry_point_tests" => item["entry_point_tests"],
        "via_constant" => item["via_constant"]
      }
    end

    def constant_hash(item)
      node = item["new"] || item["old"]
      {
        "id" => item["id"],
        "change" => item["change"],
        "file" => node.file,
        "name" => node.qualified,
        "bare_name" => node.bare_name,
        "start_line" => node.start_line,
        "end_line" => node.end_line,
        "old_source" => item["old"]&.source,
        "new_source" => item["new"]&.source,
        "readers" => item["readers"]
      }
    end

    def signature_of(change, old_node, new_node)
      return "added" if change == "added"
      return "removed" if change == "removed"

      old_node.params == new_node.params ? "same" : "changed"
    end

    def assign_ids(items, prefix)
      items.sort_by! { |item| identity_sort(item) }
      width = [2, items.size.to_s.length].max
      items.each_with_index { |item, index| item["id"] = format("%s%0#{width}d", prefix, index + 1) }
    end

    def identity_sort(item)
      node = item["new"] || item["old"]
      [node.file, node.qualified, item["change"]]
    end

    def identity(node)
      [node.file, node.qualified]
    end

    def index_by(nodes)
      nodes.to_h { |node| [identity(node), node] }
    end

    def norm(text)
      text.to_s.rstrip
    end

    def cap(text)
      Text.cap_lines(text)
    end
  end

  module CoverageFile
    module_function

    def load(path)
      expanded = File.expand_path(path)
      raise UsageError, "coverage file not found: #{path}" unless File.file?(expanded)

      raw = JSON.parse(File.read(expanded))
      unless raw.is_a?(Hash) && raw["format"] == "jitcatch-coverage-v1" && raw["tests"].is_a?(Array)
        raise UsageError, "coverage file must be JSON object with format jitcatch-coverage-v1 and a tests array"
      end

      raw["tests"].map { |test|
        raise UsageError, "coverage test entries must be objects" unless test.is_a?(Hash)

        {
          "id" => test["id"].to_s,
          "file" => test["file"].to_s,
          "lines" => test["lines"].is_a?(Hash) ? test["lines"] : {}
        }
      }.sort_by { |test| [test["file"], test["id"]] }
    rescue JSON::ParserError => err
      raise UsageError, "coverage file is not JSON: #{err.message}"
    end
  end
end
