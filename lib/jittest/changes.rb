# frozen_string_literal: true

module JitTest
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
    end

    def build
      base = @git.rev(@base_ref)
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
        "intent" => intent_lines(base, head),
        "files" => files,
        "parse_errors" => (base_idx["errors"] + head_idx["errors"]).sort_by { |err| [err["ref"], err["file"], err["message"]] },
        "constants" => constants.map { |item| constant_hash(item) },
        "methods" => methods.map { |item| method_hash(item) },
        "entrypoints" => entrypoints
      }
    end

    private

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
      calls = []
      errors = []
      sources = {}
      @git.ruby_files(sha).each do |file|
        blob = @git.show(sha, file)
        next if blob.nil? || blob.bytesize > MAX_BLOB

        sources[file] = blob
        index = SourceIndex.parse(blob, file: file)
        if index.parse_error
          errors << { "ref" => label, "file" => file, "message" => index.parse_error }
          next
        end
        methods.concat(index.methods)
        constants.concat(index.constants)
        calls.concat(index.calls)
      end
      { "methods" => methods, "constants" => constants, "calls" => calls, "errors" => errors, "sources" => sources }
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
        next unless file_hunks

        old_hit = old_m && DiffParser.overlaps?(old_m.start_line, old_m.end_line, file_hunks["hunks"], "old")
        new_hit = new_m && DiffParser.overlaps?(new_m.start_line, new_m.end_line, file_hunks["hunks"], "new")
        source_diff = norm(old_m&.source) != norm(new_m&.source)
        params_diff = old_m&.params.to_s != new_m&.params.to_s
        change = if old_m && new_m
          next unless old_hit || new_hit || source_diff || params_diff

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
        next unless file_hunks

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
      found
    end

    def attach_affected(methods, constants, base_idx, head_idx)
      return if constants.empty?

      known = methods.to_h { |item| [identity(item["new"] || item["old"]), item] }
      constants.each do |const|
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
        method["reachable_from"] = upstream(node.qualified, edges).first(REACHABLE_CAP)
      end
    end

    def decorate_tests(methods, base_idx, head_idx)
      test_sources = test_sources_for(base_idx, head_idx)
      methods.each do |method|
        node = method["new"] || method["old"]
        method["existing_tests"] = if @coverage
          coverage_hits(method)
        else
          grep_hits(test_sources, node.bare_name)
        end
      end
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

        pool = head_idx["methods"].select { |method| method.qualifier == qualifier && method.visibility == "public" }
        pool = base_idx["methods"].select { |method| method.qualifier == qualifier && method.visibility == "public" } if pool.empty?
        changed = methods.to_h { |method| [(method["new"] || method["old"]).qualified, method["change"]] }
        listed = pool.map { |method|
          { "name" => method.qualified, "role" => changed[method.qualified] || "unchanged" }
        }.sort_by { |item| [item["role"] == "unchanged" ? 1 : 0, item["name"]] }
        next if listed.empty?

        { "class" => qualifier, "methods" => listed.first(ENTRY_CAP) }
      end
    end

    def edges_for(idx)
      methods = idx["methods"]
      by_class = methods.group_by { |method| [method.qualifier, method.bare_name] }
      by_bare = methods.group_by(&:bare_name)
      edges = []
      idx["calls"].each do |call|
        next if call.enclosing.nil? || test_file?(call.file)

        qualifier, _sep, _bare = SourceIndex.split_qualified(call.enclosing)
        same = by_class[[qualifier, call.bare_name]] || []
        instance = same.select { |method| method.kind == "instance" }
        target = if instance.size == 1
          instance.first
        elsif same.size == 1
          same.first
        elsif by_bare[call.bare_name]&.size == 1
          by_bare[call.bare_name].first
        end
        next if target.nil? || target.qualified == call.enclosing

        edges << { "from" => call.enclosing, "to" => target.qualified, "file" => call.file, "line" => call.line }
      end
      edges.uniq { |edge| [edge["from"], edge["to"], edge["file"], edge["line"]] }
        .sort_by { |edge| [edge["file"], edge["line"], edge["from"], edge["to"]] }
    end

    def upstream(qualified, edges)
      reverse = Hash.new { |hash, key| hash[key] = [] }
      edges.each { |edge| reverse[edge["to"]] << edge["from"] }
      seen = []
      queue = reverse[qualified].uniq.map { |name| [name, 1] }
      until queue.empty?
        name, depth = queue.shift
        next if name == qualified || seen.include?(name)

        seen << name
        next if depth >= UPSTREAM_DEPTH

        reverse[name].each { |parent| queue << [parent, depth + 1] unless seen.include?(parent) }
      end
      seen.sort
    end

    def intent_lines(base, head)
      raw = @git.log_messages(base, head)
      messages = raw.split("\x1e").filter_map do |message|
        lines = message.lines.map(&:strip).reject(&:empty?)
        lines.empty? ? nil : lines
      end
      return [] if messages.empty?

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
      return "same" if old_node.nil? || new_node.nil?

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
      unless raw.is_a?(Hash) && raw["format"] == "jittest-coverage-v1" && raw["tests"].is_a?(Array)
        raise UsageError, "coverage file must be JSON object with format jittest-coverage-v1 and a tests array"
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
