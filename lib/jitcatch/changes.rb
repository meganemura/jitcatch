# frozen_string_literal: true
# rbs_inline: enabled

module JitCatch
  # Builds the deterministic change document shared by `context` and `run`.
  #
  # An entry of the change (`item`) and an index of one side (`idx`) are
  # hashes, typed as `doc`. A node is a SourceIndex::Method or a
  # SourceIndex::Constant, and the helpers that take either take it untyped.
  class Changes
    # @rbs!
    #   type node = SourceIndex::Method | SourceIndex::Constant
    #   type edge = Hash[String, untyped]
    #   type lookups = [Hash[[String, String], Array[SourceIndex::Method]], Hash[String, Array[SourceIndex::Method]], Hash[String, Array[SourceIndex::Method]], Hash[String, String]]

    MAX_BLOB = 200_000 #: Integer
    CALLSITE_CAP = 8 #: Integer
    REACHABLE_CAP = 8 #: Integer
    TEST_CAP = 5 #: Integer
    ENTRY_CAP = 12 #: Integer
    UPSTREAM_DEPTH = 4 #: Integer
    RECORD_BUILDERS = %w[create create! build].freeze #: Array[String]
    # A value the source does not type, whether or not its name names a model.
    UNTYPED_RECEIVERS = %w[unknown named].freeze #: Array[String]

    # The classes and modules head defines, after `build`.
    attr_reader :head_constants #: Array[String]

    # @rbs @git: GitRepo
    # @rbs @readers: bool
    # @rbs @setup: String?
    # @rbs @databases: Array[String]
    # @rbs @base_ref: String
    # @rbs @head_ref: String
    # @rbs @coverage: Array[doc]?
    # @rbs @texts: Hash[String, String]
    # @rbs @parsed: Hash[[String, String], SourceIndex]
    # @rbs @test_names: Hash[String, Array[String]]
    # @rbs @callers_index: Hash[Array[edge], Hash[String, Array[String]]]?

    # `readers: true` adds the code that reads each changed value without
    # calling it by name, which only `context` prints.
    #: (GitRepo | String repo, String base_ref, String head_ref, ?coverage: String?, ?setup: String?, ?databases: Array[String], ?readers: bool) -> doc
    def self.between(repo, base_ref, head_ref, coverage: nil, setup: nil, databases: [], readers: false)
      new(repo, base_ref, head_ref, coverage: coverage, setup: setup, databases: databases, readers: readers).build
    end

    # `setup` is the command `run --setup` runs in each checkout, and
    # `databases` the numbered test databases, base and head in turn.
    #: (GitRepo | String repo, String base_ref, String head_ref, ?coverage: String?, ?setup: String?, ?databases: Array[String], ?readers: bool) -> void
    def initialize(repo, base_ref, head_ref, coverage: nil, setup: nil, databases: [], readers: false)
      @git = repo.is_a?(GitRepo) ? repo : GitRepo.new(repo)
      @readers = readers
      @setup = setup
      @databases = databases
      @base_ref = base_ref
      @head_ref = head_ref
      @coverage = coverage.nil? ? nil : CoverageFile.load(coverage)
      @texts = {}
      @parsed = {}
      @test_names = {}
    end

    #: () -> doc
    def build
      base = @git.base_rev(@base_ref)
      head = @git.rev(@head_ref)
      files = DiffParser.name_status(@git.name_status(base, head))
      diff = DiffParser.parse(@git.diff(base, head))
      hunks = index_hunks(diff)
      base_idx = index_ref(base, "base")
      head_idx = index_ref(head, "head")
      @head_constants = lookups(head_idx)[2].keys.reject(&:empty?).sort
      methods = changed_methods(base_idx, head_idx, hunks)
      constants = changed_constants(base_idx, head_idx, hunks, methods)
      attach_affected(methods, constants, base_idx, head_idx)
      assign_ids(methods, "m")
      assign_ids(constants, "k")
      link_constants(methods, constants)
      head_edges = edges_for(head_idx)
      base_edges = edges_for(base_idx)
      decorate_calls(methods, head_edges, base_edges)
      mark_forwarders(methods, head_edges, hunks)
      mark_raise_edits(methods)
      decorate_dynamic_callers(methods, head_idx, base_idx)
      factories = factories_of(head_idx)
      builders = builders_for(methods, head_idx, factories)
      decorate_callbacks(methods, base_idx, head_idx, factories, head_edges, base_edges)
      decorate_tests(methods, base_idx, head_idx, builders)
      entrypoints = entrypoints_for(methods, head_idx, base_idx)
      readers = @readers ? implicit_readers(base_idx, head_idx, diff, methods, constants, base, head) : nil

      {
        "version" => VERSION,
        "base" => base,
        "head" => head,
        "existing_tests_via" => @coverage ? "coverage" : "grep",
        "warnings" => warnings(base, head) + schema_warnings(head, files) + computed_path_warnings(methods),
        "intent" => intent_lines(base, head),
        "files" => files,
        "dependencies" => dependencies(base, head),
        "parse_errors" => (base_idx["errors"] + head_idx["errors"]).sort_by { |err| [err["ref"], err["file"], err["message"]] },
        "constants" => constants.map { |item| constant_hash(item) },
        "methods" => methods.map { |item| method_hash(item) },
        "changed_lines" => changed_lines(hunks),
        "entrypoints" => entrypoints,
        "factories_skipped" => factories.select(&:reason).map { |factory| { "file" => factory.file, "line" => factory.line, "name" => factory.name, "reason" => factory.reason } }
      }.merge(readers ? { "readers" => readers } : {})
    end

    private

    #: (String base, String head) -> Array[String]
    def warnings(base, head)
      return ["base and head are the same commit, so the diff is empty. Pass the parent of the change as BASE."] if base == head

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

    # A Grape path built from code the source does not settle has no
    # verb and path a request could be matched to.
    #: (Array[doc] methods) -> Array[String]
    def computed_path_warnings(methods)
      methods.filter_map do |method|
        node = method["new"] || method["old"]
        next unless node.kind == "endpoint" && SourceIndex.computed_path?(node.bare_name)

        "#{node.qualified} (#{node.file}:#{node.start_line}) builds its path from code jitcatch does not run, so no request a test sends is tied to it."
      end
    end

    # Rails keeps a schema in db/schema.rb or db/structure.sql, and a
    # second database's in db/<name>_schema.rb, beside db/<name>_migrate/.
    SCHEMA_FILE = %r{\Adb/(?:\w+_)?(?:schema\.rb|structure\.sql)\z|\Adb/(?:\w+_)?migrate/} #: Regexp
    TEST_HELPERS = %w[spec/rails_helper.rb spec/spec_helper.rb test/test_helper.rb].freeze #: Array[String]

    # A test database made once from one schema holds neither side's after
    # a change to it, so a row can fail on a missing column and read as a
    # regression. A helper that calls maintain_test_schema! loads the
    # schema of the checkout it boots in; without one, only --setup can.
    # The app is the directory jitcatch runs in, so its schema and helpers
    # sit under the repository path of that directory.
    #: (String head, Array[doc] files) -> Array[String]
    def schema_warnings(head, files)
      prefix = @git.prefix
      changed = files.map { |file| file["file"] }.select { |path| path.start_with?(prefix) && path.delete_prefix(prefix).match?(SCHEMA_FILE) }.sort
      return [] if changed.empty?

      warning = "head changes the database schema (#{changed.join(", ")}), so each side's test database must hold that side's schema, " \
                "or a row can fail on the database and not on the code."
      return ["#{warning} `--setup` ran `#{@setup}` in each checkout before the candidates."] if @setup

      helpers = TEST_HELPERS.map { |path| "#{prefix}#{path}" }.select { |path| @git.show(head, path) }
      return [warning] if helpers.empty? || helpers.any? { |path| @git.show(head, path).to_s.include?("maintain_test_schema!") }

      databases = @databases.each_slice(2).map { |base, head_db| "base #{base}, head #{head_db}" }
      into = databases.empty? ? "its own test database" : "its own test database (#{databases.join("; ")})"
      ["#{warning} #{helpers.join(" and ")} #{helpers.one? ? "does" : "do"} not call `ActiveRecord::Migration.maintain_test_schema!`, so no candidate loads either schema: " \
       "pass `--setup 'bin/rails db:create db:schema:load'` to `jitcatch run` to load each side's schema into #{into} before the candidates run."]
    end

    # Each spec line in a lockfile is four spaces, a name, and the version
    # in parentheses. A gem locked for several platforms has several lines.
    # The lockfile is the one beside the Gemfile of the directory jitcatch
    # runs in.
    #: (String base, String head) -> Array[doc]
    def dependencies(base, head)
      old = locked_versions(base)
      new = locked_versions(head)
      (old.keys | new.keys).sort.filter_map do |gem|
        next if old[gem] == new[gem]

        { "gem" => gem, "old" => old[gem], "new" => new[gem] }
      end
    end

    #: (String sha) -> Hash[String, String]
    def locked_versions(sha)
      specs = @git.show(sha, "#{@git.prefix}Gemfile.lock").to_s.scan(/^    (\S+) \(([^)]+)\)$/) #: Array[[String, String]]
      specs.group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).uniq.sort.join(" ") }
    end

    # The head lines each Ruby file's hunks wrote, as inclusive ranges, so a
    # call on an edited line counts as changed code even outside any method.
    #: (Hash[String, doc] hunks) -> Hash[String, Array[[Integer, Integer]]]
    def changed_lines(hunks)
      hunks.filter_map { |path, file|
        ranges = file["hunks"].reject { |hunk| hunk["new_count"].zero? }.map { |hunk| [hunk["new_start"], hunk["new_start"] + hunk["new_count"] - 1] }
        [path, ranges] if file["new_path"] && ranges.any?
      }.sort.to_h
    end

    #: (Array[doc] files) -> Hash[String, doc]
    def index_hunks(files)
      map = {} #: Hash[String, doc]
      files.each do |file|
        path = file["new_path"] || file["old_path"]
        next unless path&.end_with?(".rb") || SourceIndex.script_path?(path.to_s)

        map[path] = file
      end
      map
    end

    #: (String sha, String label) -> doc
    def index_ref(sha, label)
      methods = [] #: Array[SourceIndex::Method]
      constants = [] #: Array[SourceIndex::Constant]
      namespaces = [] #: Array[SourceIndex::Constant]
      superclasses = [] #: Array[SourceIndex::Superclass]
      calls = [] #: Array[SourceIndex::Call]
      private_constants = [] #: Array[String]
      hidden_new = [] #: Array[String]
      errors = [] #: Array[doc]
      sources = {} #: Hash[String, String]
      indexes = {} #: Hash[String, SourceIndex]
      templates = {} #: Hash[String, String]
      template_calls = [] #: Array[SourceIndex::Call]
      listed = @git.source_blobs(sha).select { |blob| blob.size <= MAX_BLOB }
      @texts.merge!(@git.read_blobs(listed.map(&:oid).uniq - @texts.keys))
      scripts, listed = listed.partition { |blob| SourceIndex.script_path?(blob.path) }
      # An executable that is not Ruby, such as a shell `bin/setup`, is not read.
      scripts.select! { |blob| SourceIndex.ruby_script?(@texts.fetch(blob.oid)) }
      listed, views = listed.partition { |blob| blob.path.end_with?(".rb") }
      # A template defines no method, so its calls only add call sites, each
      # made from the template itself.
      views.each do |blob|
        templates[blob.path] = @texts.fetch(blob.oid)
        index = (@parsed[[blob.path, blob.oid]] ||= SourceIndex.parse(Template.as_ruby(templates[blob.path]), file: blob.path))
        template_calls.concat(index.calls.map { |call| call.with(enclosing: call.enclosing || blob.path) }) unless index.parse_error
      end
      (listed + scripts).sort_by(&:path).each do |blob|
        file = blob.path
        sources[file] = @texts.fetch(blob.oid)
        # A file both sides share is parsed once.
        index = (@parsed[[file, blob.oid]] ||= SourceIndex.parse(sources[file], file: file, script: scripts.include?(blob)))
        indexes[file] = index
        if index.parse_error
          errors << { "ref" => label, "file" => file, "message" => index.parse_error }
          next
        end
        methods.concat(index.methods)
        constants.concat(index.constants)
        namespaces.concat(index.namespaces)
        superclasses.concat(index.superclasses)
        calls.concat(index.calls)
        private_constants.concat(index.private_constants)
        hidden_new.concat(index.hidden_new)
      end
      methods = SourceIndex.hide_private_constants(methods, private_constants.uniq)
      { "methods" => methods, "constants" => constants, "namespaces" => namespaces, "superclasses" => superclasses, "calls" => calls, "hidden_new" => hidden_new, "errors" => errors, "sources" => sources, "indexes" => indexes,
        "templates" => templates, "template_calls" => template_calls }
    end

    #: (doc base_idx, doc head_idx, Hash[String, doc] hunks) -> Array[doc]
    def changed_methods(base_idx, head_idx, hunks)
      old_map = index_by(base_idx["methods"])
      new_map = index_by(head_idx["methods"])
      found = [] #: Array[doc]
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
      mark_moves(found, head_idx["methods"], hunks) { "moved" }
    end

    # A method that leaves one file while head defines the same name in
    # another is moved, not removed: it still answers a call. The other side
    # is read from every file, test files too, since a test double can move
    # into test/, where no change of its own is listed. A file the diff
    # touched is the likelier destination than an older copy elsewhere.
    # The block names the change a move is, from the old and the new node.
    #: (Array[doc] found, Array[untyped] head_nodes, Hash[String, doc] hunks) { (untyped, untyped) -> String } -> Array[doc]
    def mark_moves(found, head_nodes, hunks)
      by_name = head_nodes.group_by(&:qualified)
      found.select { |item| item["change"] == "removed" && !item["namespace"] }.each do |item|
        old_m = item["old"]
        dest = Array(by_name[old_m.qualified]).reject { |node| node.file == old_m.file }
          .min_by { |node| [hunks.key?(node.file) ? 0 : 1, node.file] }
        next unless dest

        found.reject! { |other| other["change"] == "added" && identity(other["new"]) == identity(dest) }
        item.merge!("change" => yield(old_m, dest), "new" => dest, "moved_from" => old_m.file)
      end
      found
    end

    #: (doc base_idx, doc head_idx, Hash[String, doc] hunks, Array[doc] _methods) -> Array[doc]
    def changed_constants(base_idx, head_idx, hunks, _methods)
      old_map = index_by(base_idx["constants"])
      new_map = index_by(head_idx["constants"])
      found = [] #: Array[doc]
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

        found << {
          "change" => change, "old" => old_c, "new" => new_c,
          "read_by" => [] #: Array[String]
        }
      end
      # A constant that keeps its value in its new file is moved, and its
      # readers see nothing new; one whose value changed on the way is modified.
      mark_moves(found, head_idx["constants"], hunks) { |old_c, new_c| norm(value_of(old_c)) == norm(value_of(new_c)) ? "moved" : "modified" }
      found + changed_namespaces(base_idx, head_idx, hunks)
    end

    #: (SourceIndex::Constant const) -> String
    def value_of(const)
      const.source.sub(/A[^=]*=/, "").strip
    end

    # A class or module counts only when the other side defines it nowhere,
    # so a file that reopens an existing namespace adds nothing. Its body
    # changes show up as the methods and constants inside it.
    #: (doc base_idx, doc head_idx, Hash[String, doc] hunks) -> Array[doc]
    def changed_namespaces(base_idx, head_idx, hunks)
      old_names = base_idx["namespaces"].map(&:qualified)
      new_names = head_idx["namespaces"].map(&:qualified)
      removed = base_idx["namespaces"].reject { |node| new_names.include?(node.qualified) }
      added = head_idx["namespaces"].reject { |node| old_names.include?(node.qualified) }
      found = removed.uniq(&:qualified).filter_map { |node|
        next unless hunks[node.file] && !test_file?(node.file)

        { "change" => "removed", "old" => node, "new" => nil,
          "read_by" => [], #: Array[String]
          "namespace" => true }
      }
      found + added.uniq(&:qualified).filter_map { |node|
        next unless hunks[node.file] && !test_file?(node.file)

        { "change" => "added", "old" => nil, "new" => node,
          "read_by" => [], #: Array[String]
          "namespace" => true }
      }
    end

    #: (Array[doc] methods, Array[doc] constants, doc base_idx, doc head_idx) -> void
    def attach_affected(methods, constants, base_idx, head_idx)
      return if constants.empty?

      known = methods.to_h { |item| [identity(item["new"] || item["old"]), item] }
      constants.each do |const|
        next if const["namespace"] || const["change"] == "moved"

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

    #: (Array[doc] methods, Array[doc] constants) -> void
    def link_constants(methods, constants)
      constants.each do |const|
        bare = (const["new"] || const["old"]).bare_name
        pattern = /\b#{Regexp.escape(bare)}\b/
        const["read_by"] = methods.filter_map { |method|
          sources = [method["old"]&.source, method["new"]&.source].compact
          method["id"] if sources.any? { |source| source.match?(pattern) }
        }.uniq.sort
      end
      methods.each do |method|
        next unless method["change"] == "affected"

        related = constants.select { |const| const["read_by"].include?(method["id"]) }
        method["via_constant"] = related.map { |const| const["id"] }.min
      end
    end

    #: (Array[doc] methods, Array[edge] head_edges, Array[edge] base_edges) -> void
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
        # Every method that reaches this one, at any depth and with no cap,
        # with the fewest calls between them. A test that enters high, as a
        # request spec or a CLI test does, calls a method above the callers
        # `upstream` keeps, so the assessor reads this set instead.
        method["caller_depths"] = callers_by_depth(node.qualified, edges, nil)
      end
    end

    # An edit whose every added line calls a method the diff added, and that
    # removes no more lines than it adds, only routes a value from that
    # method, as `net - volume` becoming `net - volume - coupon` does. The
    # new value then comes from the added method, not from this one.
    #: (Array[doc] methods, Array[edge] head_edges, Hash[String, doc] hunks) -> void
    def mark_forwarders(methods, head_edges, hunks)
      added = methods.select { |method| method["change"] == "added" }.map { |method| method["new"].qualified }
      methods.each do |method|
        method["forwards_to_added"] = method["change"] == "modified" && added.any? && forwards?(method["new"], added, head_edges, hunks)
      end
    end

    # An edit that changes only the arguments of a `raise` changes what the
    # method raises, not whether it does. A test whose expected error head
    # stopped raising then points at the code that stopped calling it, so
    # the assessor ranks such a method after the others.
    #: (Array[doc] methods) -> void
    def mark_raise_edits(methods)
      methods.each do |method|
        method["edits_only_raise"] = method["change"] == "modified" &&
          method["old"].source != method["new"].source &&
          without_raises(method["old"].source) == without_raises(method["new"].source)
      end
    end

    # The source with each receiverless `raise` or `fail` call written as
    # the bare word, so two sources that differ only there compare equal.
    #: (String source) -> String
    def without_raises(source)
      text = source.b
      pending = [Prism.parse(source).value] #: Array[Prism::Node]
      spans = [] #: Array[[Integer, Integer]]
      until pending.empty?
        node = pending.pop #: Prism::Node
        if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[raise fail].include?(node.name)
          spans << [node.location.start_offset, node.location.end_offset]
        else
          pending.concat(node.compact_child_nodes)
        end
      end
      spans.sort.reverse_each { |first, last| text = text.byteslice(0, first).to_s + "raise".b + text.byteslice(last..).to_s }
      text
    end

    #: (SourceIndex::Method node, Array[String] added, Array[edge] head_edges, Hash[String, doc] hunks) -> bool
    def forwards?(node, added, head_edges, hunks)
      lines = [] #: Array[Integer]
      removed = 0
      file_hunks = hunks.dig(node.file, "hunks") || [] #: Array[doc]
      file_hunks.each do |hunk|
        inside = (hunk["new_start"]...(hunk["new_start"] + hunk["new_count"])).select { |line| line.between?(node.start_line, node.end_line) }
        # A pure deletion has no new lines; git puts it after new_start.
        deletion = hunk["new_count"].zero? && hunk["new_start"] >= node.start_line && hunk["new_start"] < node.end_line
        next if inside.empty? && !deletion

        lines.concat(inside)
        removed += hunk["old_count"]
      end
      calls = head_edges.filter_map { |edge| edge["line"] if edge["from"] == node.qualified && edge["file"] == node.file && added.include?(edge["to"]) }
      lines.any? && removed <= lines.size && (lines - calls).empty?
    end

    # A method that sends the name of a changed method, or of one that
    # reaches it, to a receiver the source does not name, as in
    # `EMITTERS.fetch(format).render`, may reach it, but no edge says so.
    # The router calls a controller action, and no code in the app sends
    # its name, so `cipher.update` does not reach `ThingsController#update`.
    #: (Array[doc] methods, doc head_idx, doc base_idx) -> void
    def decorate_dynamic_callers(methods, head_idx, base_idx)
      methods.each do |method|
        node = method["new"] || method["old"]
        idx = method["change"] == "removed" ? base_idx : head_idx
        sent = [node.qualified, *method["reachable_from"]].reject { |name| controller_action?(name) }
        names = sent.to_h { |name| [SourceIndex.split_qualified(name).last, name] }
        callers = idx["calls"].filter_map do |call|
          next unless UNTYPED_RECEIVERS.include?(call.receiver.kind) && names.key?(call.bare_name) && call.enclosing && !test_file?(call.file)
          next if call.enclosing == node.qualified || method["reachable_from"].include?(call.enclosing)

          { "from" => call.enclosing, "name" => call.bare_name }
        end
        method["dynamic_callers"] = callers.uniq.sort_by { |caller| [caller["from"], caller["name"]] }.first(REACHABLE_CAP)
      end
    end

    #: (String name) -> bool
    def controller_action?(name)
      owner, sep, = SourceIndex.split_qualified(name)
      sep == "#" && owner.split("::").last.to_s.end_with?("Controller")
    end

    #: (Array[doc] methods, doc base_idx, doc head_idx, Hash[String, Array[String]] builders) -> void
    def decorate_tests(methods, base_idx, head_idx, builders)
      test_sources = test_sources_for(base_idx, head_idx)
      public_names = (base_idx["methods"] + head_idx["methods"]).filter_map { |node| [node.qualified, true] if node.visibility == "public" }.to_h
      routes = nil #: Routes?
      requests = nil #: Hash[String, Hash[String, Array[String]]]?
      methods.each do |method|
        node = method["new"] || method["old"]
        method["builders"] = constructor?(node) ? builders.fetch(node.qualifier) : []
        method["existing_tests"] = if @coverage
          coverage_hits(method)
        else
          # No test calls `initialize` by that name, so a file that writes
          # the word only reads or names the method.
          if constructor?(node)
            merge_hits(call_hits(test_sources.keys, ["#{node.qualifier}.new", *method["builders"]], "builder", base_idx, head_idx), [])
          elsif node.kind == "endpoint"
            request_hits(test_sources, node.bare_name)
          elsif node.kind == "script"
            # A test starts an executable by its path, as `exe/tool` or
            # `../exe/tool`, not by a method name.
            grep_hits(test_sources, node.file)
          elsif controller_action?(node.qualified) && (drawn = (routes ||= app_routes(head_idx))).drawn?(node.qualified)
            route_hits(test_sources, node.qualified, requests ||= test_requests(test_sources, drawn, base_idx, head_idx))
          else
            merge_hits(call_hits(test_sources.keys, method["run_by"], "callback", base_idx, head_idx), grep_hits(test_sources, node.bare_name, owner_pattern(node)))
          end
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
    #: (Hash[String, String] test_sources, Array[String] entry_points) -> Array[doc]
    def entry_point_hits(test_sources, entry_points)
      found = Hash.new { |hash, file| hash[file] = [] }
      entry_points.each do |name|
        qualifier, _sep, bare = SourceIndex.split_qualified(name)
        owner = qualifier.split("::").last
        call = /\.#{called(bare)}/
        named = owner && /\b#{Regexp.escape(owner)}\b(?!::)/
        # A request names its endpoint by verb and path, never by class.
        call, named = request_pattern(bare), nil if SourceIndex.endpoint?(bare)
        test_sources.each do |file, source|
          found[file] << name if source.match?(call) && (named.nil? || source.match?(named))
        end
      end
      found.keys.sort.first(TEST_CAP).map { |file| { "file" => file, "entry_points" => found[file].sort } }
    end

    #: (doc method) -> Array[doc]
    def coverage_hits(method)
      node = method["new"] || method["old"]
      start_line = node.start_line
      end_line = node.end_line
      # Only a run with a coverage file asks for coverage hits.
      coverage = @coverage #: Array[doc]
      coverage.filter_map { |test|
        lines = test.dig("lines", node.file)
        next unless lines.is_a?(Array)
        next unless lines.any? { |line| line.is_a?(Integer) && line >= start_line && line <= end_line }

        { "file" => test["file"].to_s, "test" => test["id"].to_s, "via" => "coverage" }
      }.sort_by { |hit| [hit["file"], hit["test"]] }.first(TEST_CAP)
    end

    # A test file that sends the endpoint's verb to a path ending in its
    # segments, as a request spec does.
    #: (Hash[String, String] test_sources, String bare) -> Array[doc]
    def request_hits(test_sources, bare)
      pattern = request_pattern(bare)
      test_sources.filter_map { |file, source| { "file" => file, "via" => "grep" } if source.match?(pattern) }
        .sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # `post "/v1/things/#{thing.id}/refresh"` for `POST /things/:id/refresh`:
    # any segments before the endpoint's, a `:param` matching any one. A
    # path that starts with an interpolation, as `"#{api_root}/things/..."`,
    # computes its mount point, so it may name only the endpoint's last
    # segments, at least two of them.
    #: (String bare) -> Regexp
    def request_pattern(bare)
      verb, path = bare.split(" ", 2) #: [String, String]
      segment = %q{[^"'?/\s]+}
      parts = path.split("/").reject(&:empty?).map { |part| part.start_with?(":") ? segment : Regexp.escape(part) }
      suffixes = parts.size.downto([parts.size, 2].min).map { |count| parts.last(count).join("/") }
      interpolation = '#\{[^}"\'\n]*\}'
      full = "(?:/#{segment})*/#{parts.join("/")}"
      computed_mount = "#{interpolation}(?:#{suffixes.map { |suffix| "/#{suffix}" }.join("|")})"
      Regexp.new(%Q{\\b#{verb.downcase}[\\s(]+["'](?:#{full}|#{computed_mount})/?["'?]})
    end

    #: (doc idx) -> Routes
    def app_routes(idx)
      Routes.parse(idx["sources"]["config/routes.rb"], app_inflections(idx))
    end

    #: (doc idx) -> Inflections
    def app_inflections(idx)
      Inflections.read(idx["sources"]["config/initializers/inflections.rb"])
    end

    # Each value the change edits, with the code at head that reads it some
    # way other than a call by name. A row at one of a method's call sites,
    # or a plain read inside a method a constant already lists as reading
    # it, says nothing those lists do not, so it is left out.
    #: (doc base_idx, doc head_idx, Array[doc] diff, Array[doc] methods, Array[doc] constants, String base, String head) -> doc
    def implicit_readers(base_idx, head_idx, diff, methods, constants, base, head)
      values, rows = Readers.between(
        base_sources: base_idx["sources"], head_sources: head_idx["sources"].merge(head_idx["templates"]),
        diff: diff, routes: app_routes(head_idx), inflections: app_inflections(head_idx)
      )
      items = values.to_h { |value| [value, listed_item(value, methods, constants)] }
      rows = rows.reject { |row| shown_elsewhere?(row, items[row.value], methods) }
      counts = rows.group_by(&:value).transform_values(&:size)
      {
        "values" => values.map { |value|
          { "value" => value.label, "kind" => value.kind.to_s, "change" => value.state.to_s, "id" => items[value]&.fetch("id"),
            "rev" => value.state == :removed ? base : head, "file" => value.file, "line" => value.line, "readers" => counts.fetch(value, 0) }
        },
        "rows" => rows.map { |row|
          { "value" => row.value.label, "id" => items[row.value]&.fetch("id"), "rev" => head, "file" => row.file, "line" => row.line,
            "edited_by_change" => row.edited, "mechanism" => row.mechanism.to_s, "score" => row.score, "rank" => row.rank,
            "why" => row.why, "also" => row.also, "test" => row.test }
        },
        "not_seen" => rails_shaped?(head_idx) ? Readers::BLIND : Readers::BLIND_OUTSIDE_RAILS
      }
    end

    # Models, routes, and templates live in app/ and config/routes.rb, so a
    # history with neither, as a gem's, hides none of what Rails would.
    #: (doc idx) -> bool
    def rails_shaped?(idx)
      paths = idx["sources"].keys + idx["templates"].keys
      paths.any? { |path| path.start_with?("app/") || %w[config/application.rb config/routes.rb].include?(path) }
    end

    # The method or constant entry a value is, by its name and where it is
    # declared. A setting, a callback, or a default has none.
    #: (Readers::Value value, Array[doc] methods, Array[doc] constants) -> doc?
    def listed_item(value, methods, constants)
      items = { constant: constants, method: methods, scope: methods }.fetch(value.kind, [])
      items.find do |item|
        node = value.state == :removed ? item["old"] : item["new"]
        node && node.file == value.file && node.start_line == value.line && node.bare_name == value.name
      end
    end

    #: (Readers::Row row, doc? item, Array[doc] methods) -> bool
    def shown_elsewhere?(row, item, methods)
      return false unless item

      if item.key?("callsites")
        item["callsites"].any? { |site| site["file"] == row.file && site["line"] == row.line }
      else
        row.mechanism == :constant_read && methods.any? do |method|
          node = method["new"]
          item["read_by"].include?(method["id"]) && node && node.file == row.file && row.line.between?(node.start_line, node.end_line)
        end
      end
    end

    # The files whose requests the routes send to the action, as `run`
    # reads them, and the controller tests that name the controller and
    # call the action by its symbol (`post :create`). A bare-name grep
    # matched `create(:book)` and missed `post books_path`.
    #: (Hash[String, String] test_sources, String action, Hash[String, Hash[String, Array[String]]] requests) -> Array[doc]
    def route_hits(test_sources, action, requests)
      owner, _sep, bare = SourceIndex.split_qualified(action)
      controller_call = /\b(?:#{SourceIndex::ENDPOINT_VERBS.join("|")})[\s(]+:#{called(bare)}/
      named = /\b#{Regexp.escape(owner.split("::").last)}\b/
      test_sources.filter_map { |file, source|
        calls = requests[file].filter_map { |request, actions| request if actions.include?(action) }
        if source.match?(named)
          # The pattern has no group, so each match is a String.
          written = source.scan(controller_call) #: Array[String]
          calls += written.map { |call| call.sub(/[\s(]+/, " ") }.uniq
        end
        { "file" => file, "via" => "route", "calls" => calls.sort } unless calls.empty?
      }.first(TEST_CAP)
    end

    # Each test file's requests, with the controller actions they reach.
    #: (Hash[String, String] test_sources, Routes routes, doc base_idx, doc head_idx) -> Hash[String, Hash[String, Array[String]]]
    def test_requests(test_sources, routes, base_idx, head_idx)
      test_sources.keys.to_h { |file|
        index = head_idx["indexes"][file] || base_idx["indexes"][file]
        [file, index.referenced_names("").select { |name| SourceIndex.request?(name) }.to_h { |request| [request, routes.actions(request)] }]
      }
    end

    # `owner`, when given, is a pattern the file must match too.
    #: (Hash[String, String] test_sources, String? bare, ?Regexp? owner) -> Array[doc]
    def grep_hits(test_sources, bare, owner = nil)
      return [] if bare.nil? || bare.length < 3

      pattern = /\b#{called(bare)}/
      test_sources.filter_map { |file, source|
        next unless source.match?(pattern) && (owner.nil? || source.match?(owner))

        { "file" => file, "via" => "grep" }
      }.sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # A reader or a member (`attr_reader :file`, `Data.define(:code, :line)`)
    # is most often a common word, which a grep finds in files that never
    # touch the class. Such a hit counts only in a file that also names the
    # class or the namespace around it, as `Hit` or `Targets` for
    # `Targets::Hit#code`.
    MEMBER_MACRO = /\A(?:attr_reader|attr_writer|Struct\.new|Data\.define)\z/ #: Regexp

    #: (SourceIndex::Method node) -> Regexp?
    def owner_pattern(node)
      return nil unless MEMBER_MACRO.match?(node.macro.to_s)

      words = node.qualifier.split("::").last(2)
      words.empty? ? nil : /\b(?:#{words.map { |word| Regexp.escape(word) }.join("|")})\b/
    end

    # A factory that builds a class no file defines may need an inflection
    # the app configures (`ApiKey` against `APIKey`), so it is not followed.
    # One that builds a Ruby value, as `class: Hash` does for the shape of an
    # API response, builds no class of the app, so nothing is skipped. The
    # list is fixed so that every Ruby prints the same document.
    RUBY_VALUE_CLASSES = %w[Array Data Hash Object OpenStruct Set String Struct].freeze #: Array[String]

    #: (doc idx) -> Array[Factories::Factory]
    def factories_of(idx)
      defined = lookups(idx)[2]
      Factories.read(idx["sources"].select { |path, _source| Factories.file?(path) }).filter_map do |factory|
        next factory if factory.reason || defined.key?(factory.class_name)
        next if RUBY_VALUE_CLASSES.include?(factory.class_name.to_s.delete_prefix("::"))

        factory.with(reason: "it builds #{factory.class_name}, which no file here defines")
      end
    end

    # The calls other than `new` that run a changed class's `initialize`:
    # `create`, `create!`, and `build` on an ActiveRecord model, and each
    # factory that builds the class.
    #: (Array[doc] methods, doc idx, Array[Factories::Factory] factories) -> Hash[String, Array[String]]
    def builders_for(methods, idx, factories)
      by_class, _by_bare, _qualifiers, parents = lookups(idx)
      methods.map { |method| (method["new"] || method["old"]).qualifier }.uniq.to_h do |qualifier|
        records = RECORD_BUILDERS.filter_map { |bare| "#{qualifier}.#{bare}" if constructor_of(qualifier, bare, by_class, parents) }
        [qualifier, (records + factory_mentions(qualifier, factories)).sort]
      end
    end

    # A factory whose association builds the class runs its constructor and
    # its save callbacks too: `create(:loan)` saves the Borrower that
    # `borrower` builds, and `build(:loan)` builds it unsaved. A trait's
    # associations build only when the test names the trait.
    #: (String qualifier, Array[Factories::Factory] factories) -> Array[String]
    def factory_mentions(qualifier, factories)
      factories.reject(&:reason).flat_map do |factory|
        traits = factory.trait_builds.select { |_trait, classes| classes.include?(qualifier) }.keys #: Array[String?]
        traits.unshift(nil) if factory.class_name == qualifier || factory.builds.include?(qualifier)
        traits.product(%w[build create]).map { |trait, call| SourceIndex.factory_mention(factory.name, call, trait) }
      end
    end

    # The calls that run a changed method because a model's class body
    # names it, or names a method that reaches it, in a callback or a
    # validation (`after_save :count_save`). A factory of the model counts
    # where `.create` does: `create(:loan)` saves a new record. `build(:loan)`
    # counts there too, but a test hit needs the test to save or validate
    # the record as well (`call_hits`).
    #: (Array[doc] methods, doc base_idx, doc head_idx, Array[Factories::Factory] factories, Array[edge] head_edges, Array[edge] base_edges) -> void
    def decorate_callbacks(methods, base_idx, head_idx, factories, head_edges, base_edges)
      base_callbacks = record_callbacks(base_idx)
      head_callbacks = record_callbacks(head_idx)
      base_calls = app_calls(base_idx)
      head_calls = app_calls(head_idx)
      methods.each do |method|
        node = method["new"] || method["old"]
        callbacks = method["change"] == "removed" ? base_callbacks : head_callbacks
        found = [node.qualified, *method["reachable_from"]].flat_map { |name| callbacks.fetch(name, []) }
        method["callbacks"] = found.map(&:declared).uniq.sort
        method["run_by"] = found.flat_map { |callback| callback_calls(callback, factories) }.uniq.sort
        calls, edges = method["change"] == "removed" ? [base_calls, base_edges] : [head_calls, head_edges]
        savers = calls.filter_map { |written, from| from if method["run_by"].any? { |run_by| SourceIndex.names_call?(written, run_by) } }.uniq.sort
        reached = savers + savers.flat_map { |name| upstream(name, edges) }
        method["reachable_from"] = (method["reachable_from"] | reached).reject { |name| name == node.qualified }.first(REACHABLE_CAP).sort
        through_saves = savers.flat_map { |name| [[name, 1], *callers_by_depth(name, edges, nil).map { |caller, depth| [caller, depth + 1] }] }
        depths = method["caller_depths"]
        through_saves.each { |name, depth| depths[name] = [depths.fetch(name, depth), depth].min unless name == node.qualified }
        method["caller_depths"] = depths.sort.to_h
        method["reached_by"] = method["caller_depths"].keys
      end
    end

    # Each call outside the tests as the repository's code writes it, with
    # the method that makes it: `Loan.create!` in `LoanDesk.open`, or
    # `Loan#update!` for `update!` inside a method of `Loan`. A written
    # `Loan` names `Shop::Loan` as it does in a test. A local the source
    # does not type, such as a parameter, is read as the model Rails names
    # it after: `loan.save!` as `Loan#save!`. Only a save reads it, since a
    # record call has no meaning on another class.
    #: (doc idx) -> Array[[String, String]]
    def app_calls(idx)
      idx["calls"].filter_map { |call|
        next if call.enclosing.nil? || test_file?(call.file)

        written = written_call(call)
        [written, call.enclosing] if written
      }
    end

    #: (SourceIndex::Call call) -> String?
    def written_call(call)
      # The caller skips a call made outside any method.
      enclosing = call.enclosing #: String
      qualifier, sep, _bare = SourceIndex.split_qualified(enclosing)
      receiver = call.receiver
      case receiver.kind
      when "self" then "#{qualifier}#{sep}#{call.bare_name}"
      when "singleton" then "#{receiver.const}.#{call.bare_name}"
      when "instance" then "#{receiver.const}##{call.bare_name}"
      when "named" then "#{SourceIndex.model_name(receiver.const)}##{call.bare_name}"
      end
    end

    # A callback line counts in a class whose superclass chain reaches
    # ActiveRecord::Base. One in a Concern runs on each class that includes
    # it, which the source does not list, so it is not followed.
    #: (doc idx) -> Hash[String, Array[SourceIndex::Callback]]
    def record_callbacks(idx)
      parents = lookups(idx)[3]
      idx["indexes"].reject { |path, _index| test_file?(path) }.values.flat_map(&:callbacks)
        .select { |callback| ancestry(callback.qualifier, parents).include?("ActiveRecord::Base") }
        .group_by { |callback| SourceIndex.qualify(callback.qualifier, callback.method, false) }
    end

    #: (SourceIndex::Callback callback, Array[Factories::Factory] factories) -> Array[String]
    def callback_calls(callback, factories)
      calls = callback.calls.map { |call| "#{callback.qualifier}#{call}" }
      calls.include?("#{callback.qualifier}.create") ? calls + factory_mentions(callback.qualifier, factories) : calls
    end

    #: (untyped node) -> bool
    def constructor?(node)
      node.bare_name == "initialize" && node.kind == "instance" && !node.qualifier.empty?
    end

    # A test file that makes one of the calls, as its parsed source writes
    # it. `Loan.new` also names `Shop::Loan` from inside `Shop`.
    #: (Array[String] paths, Array[String] calls, String via, doc base_idx, doc head_idx) -> Array[doc]
    def call_hits(paths, calls, via, base_idx, head_idx)
      return [] if calls.empty?

      record_calls = SourceIndex.record_calls(calls) if via == "callback"
      paths.filter_map { |path|
        index = head_idx["indexes"][path] || base_idx["indexes"][path]
        names = (@test_names[path] ||= index.referenced_names(""))
        found = names.select { |name| calls.any? { |call| SourceIndex.names_call?(name, call) } }
        found.reject! { |name| SourceIndex.unsaved_mention?(name) } if record_calls && !SourceIndex.saves_or_validates?(names, record_calls)
        { "file" => path, "via" => via, "calls" => found } unless found.empty?
      }
    end

    #: (Array[doc] builds, Array[doc] greps) -> Array[doc]
    def merge_hits(builds, greps)
      built = builds.map { |hit| hit["file"] }
      (builds + greps.reject { |hit| built.include?(hit["file"]) }).sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # A method name can end in `!` or `?`, where `\b` cannot follow, and
    # `save` is not a call of `save!`.
    #: (String bare) -> String
    def called(bare)
      "#{Regexp.escape(bare)}(?![\\w?!])"
    end

    #: (doc base_idx, doc head_idx) -> Hash[String, String]
    def test_sources_for(base_idx, head_idx)
      paths = (base_idx["sources"].keys | head_idx["sources"].keys).select { |path| test_file?(path) && !fixture_code?(path) }.sort
      paths.to_h { |path| [path, head_idx["sources"][path] || base_idx["sources"][path]] }
    end

    # A project kept as a fixture under test/ or spec/ (a small Rails app in
    # `test/fixture/depot`) holds code of its own in app/, lib/, config/,
    # and db/. That code tests nothing, so it is no test a `tests:` line
    # can name; the fixture's own test and spec files still are.
    FIXTURE_DIR = /\Afixtures?\z/ #: Regexp
    FIXTURE_CODE = %w[app lib config db].freeze #: Array[String]

    #: (String path) -> bool
    def fixture_code?(path)
      parts = path.split("/")
      at = parts.index { |part| FIXTURE_DIR.match?(part) }
      return false unless at && parts.first(at).any? { |part| %w[test spec].include?(part) }

      base = parts.last
      inner = parts[(at + 1)...-1] #: Array[String]
      !(base.start_with?("test_") || base.end_with?("_test.rb", "_spec.rb")) && inner.any? { |part| FIXTURE_CODE.include?(part) }
    end

    #: (String path) -> bool
    def test_file?(path)
      base = File.basename(path)
      return false unless base.end_with?(".rb")
      return true if base.start_with?("test_") || base.end_with?("_test.rb")

      parts = path.split("/")
      parts.include?("test") || parts.include?("spec")
    end

    #: (Array[doc] methods, doc head_idx, doc base_idx) -> Array[doc]
    def entrypoints_for(methods, head_idx, base_idx)
      classes = methods.map { |method| (method["new"] || method["old"]).qualifier }.uniq.sort
      classes.filter_map do |qualifier|
        next if qualifier.empty?

        side = public_methods_of(head_idx, qualifier).empty? ? base_idx : head_idx
        pool = public_methods_of(side, qualifier)
        changed = methods.to_h { |method| [(method["new"] || method["old"]).qualified, method["change"]] }
        constructor = "#{qualifier}#initialize"
        names = pool.map(&:qualified) - [constructor]
        listed = names.map { |name| { "name" => name, "role" => changed[name] || "unchanged" } }
        if [head_idx, base_idx].any? { |idx| idx["methods"].any? { |method| method.qualified == constructor } } && !side["hidden_new"].include?(qualifier)
          # A test builds the object with `.new`, which runs `initialize`.
          listed << { "name" => "#{qualifier}.new", "role" => changed[constructor] || "unchanged" }
        end
        # An unchanged method that reaches a changed one is the call a test
        # makes, so the cap leaves it in before the other unchanged ones.
        callers = methods.flat_map { |method| Array(method["reachable_from"]) }
        listed = listed.sort_by { |item| [item["role"] == "unchanged" ? 1 : 0, item["name"].end_with?(".new") ? 0 : 1, item["role"] == "unchanged" && callers.include?(item["name"]) ? 0 : 1, item["name"]] }
        next if listed.empty?

        { "class" => qualifier, "methods" => listed.first(ENTRY_CAP), "omitted" => [listed.size - ENTRY_CAP, 0].max }
      end
    end

    #: (doc idx, String qualifier) -> Array[SourceIndex::Method]
    def public_methods_of(idx, qualifier)
      idx["methods"].select { |method| method.qualifier == qualifier && method.visibility == "public" && !test_file?(method.file) }
    end

    #: (doc idx) -> Array[edge]
    def edges_for(idx)
      by_class, by_bare, qualifiers, parents = lookups(idx)
      edges = [] #: Array[edge]
      named_owners = {} #: Hash[[String, untyped], String?]
      (idx["calls"] + idx["template_calls"]).each do |call|
        next if call.enclosing.nil? || test_file?(call.file)

        targets = if call.enclosing == call.file && call.receiver.kind == "self"
          helper_target(call, by_bare)
        else
          call_target(call, by_class, by_bare, qualifiers, parents, named_owners)
        end
        found = Array(targets) #: Array[SourceIndex::Method]
        found.each do |target|
          next if target.qualified == call.enclosing

          edges << { "from" => call.enclosing, "to" => target.qualified, "file" => call.file, "line" => call.line }
        end
      end
      edges.uniq { |edge| [edge["from"], edge["to"], edge["file"], edge["line"]] }
        .sort_by { |edge| [edge["file"], edge["line"], edge["from"], edge["to"]] }
    end

    # A template calls a bare name on its view, which holds the app's helper
    # modules, so only a helper method answers it.
    #: (SourceIndex::Call call, Hash[String, Array[SourceIndex::Method]] by_bare) -> SourceIndex::Method?
    def helper_target(call, by_bare)
      found = (by_bare[call.bare_name] || []).select { |method| method.kind == "instance" && method.file.start_with?("app/helpers/") }
      found.first if found.size == 1
    end

    #: (doc idx) -> lookups
    def lookups(idx)
      methods = idx["methods"]
      by_class = methods.group_by { |method| [method.qualifier, method.bare_name] }
      by_bare = methods.group_by(&:bare_name)
      # A class with no method of its own still names a class to look up.
      named = idx["namespaces"].to_h do |node|
        [node.qualified, []] #: [String, Array[SourceIndex::Method]]
      end
      qualifiers = named.merge(methods.group_by(&:qualifier))
      parents = idx["superclasses"].to_h { |sup| [sup.qualified, resolve_constant(sup.written, sup.scope, qualifiers, defining: sup.qualified) || sup.written] }
      [by_class, by_bare, qualifiers, parents]
    end

    # A call on a receiver the source does not name gets no edge: a bare
    # name alone would send `line.strip` to any indexed `strip`. An implicit
    # `self` call still falls back to a unique bare name, for methods a class
    # gets from a module or a superclass; from an instance method, only to
    # an instance method, since no mixin turns a class method into one.
    # `named_owners` keeps the class each name resolves to from each
    # namespace, since a repository sends to the same few names many times.
    #: (SourceIndex::Call call, Hash[[String, String], Array[SourceIndex::Method]] by_class, Hash[String, Array[SourceIndex::Method]] by_bare, Hash[String, Array[SourceIndex::Method]] qualifiers, Hash[String, String] parents, ?Hash[[String, untyped], String?] named_owners) -> (SourceIndex::Method | Array[SourceIndex::Method] | nil)
    def call_target(call, by_class, by_bare, qualifiers, parents, named_owners = {})
      # The caller skips a call made outside any method.
      enclosing = call.enclosing #: String
      qualifier, sep, _bare = SourceIndex.split_qualified(enclosing)
      receiver = call.receiver
      case receiver.kind
      when "self"
        same = by_class[[qualifier, call.bare_name]] || []
        instance = same.select { |method| method.kind == "instance" }
        if instance.size == 1
          instance.first
        elsif same.size == 1
          same.first
        elsif sep == "." && (built = constructor_of(qualifier, call.bare_name, by_class, parents))
          built
        else
          inherited = (by_bare[call.bare_name] || []).select { |method| sep == "." || method.kind == "instance" }
          inherited.first if inherited.size == 1
        end
      when "singleton", "instance"
        owner = receiver.const.nil? ? qualifier : resolve_constant(receiver.const, qualifier, qualifiers)
        found = (by_class[[owner, call.bare_name]] || []).select { |method| method.kind == receiver.kind }
        if found.size == 1
          found.first
        elsif receiver.kind == "singleton"
          constructor_of(owner, call.bare_name, by_class, parents)
        end
      when "named"
        key = [qualifier, receiver.const] #: [String, untyped]
        owner = named_owners.fetch(key) { named_owners[key] = resolve_constant(SourceIndex.model_name(receiver.const), qualifier, qualifiers) }
        return nil unless owner

        found = (by_class[[owner, call.bare_name]] || []).select { |method| method.kind == "instance" }
        found.first if found.size == 1
      when "one_of"
        receiver.const.filter_map do |const|
          found = (by_class[[resolve_constant(const, qualifier, qualifiers), call.bare_name]] || []).select { |method| method.kind == "singleton" }
          found.first if found.size == 1
        end
      end
    end

    # `new` runs the nearest `initialize` up the superclass chain. On an
    # ActiveRecord model, `create`, `create!`, and `build` call `new`; on
    # another class they are methods the index cannot see, so they count
    # only there. A class method of the same name up the chain answers the
    # call instead.
    #: (String? owner, String bare, Hash[[String, String], Array[SourceIndex::Method]] by_class, Hash[String, String] parents) -> SourceIndex::Method?
    def constructor_of(owner, bare, by_class, parents)
      chain = ancestry(owner, parents)
      return nil unless bare == "new" || (RECORD_BUILDERS.include?(bare) && chain.include?("ActiveRecord::Base"))
      return nil if chain.any? { |klass| Array(by_class[[klass, bare]]).any? { |method| method.kind == "singleton" } }

      chain.each do |klass|
        found = Array(by_class[[klass, "initialize"]]).select { |method| method.kind == "instance" }
        return found.first if found.size == 1
      end
      nil
    end

    #: (String? owner, Hash[String, String] parents) -> Array[String?]
    def ancestry(owner, parents)
      chain = [owner]
      chain << parents[chain.last] while parents.key?(chain.last) && !chain.include?(parents[chain.last])
      chain
    end

    # Ruby looks a constant up from the innermost enclosing namespace out.
    # A class header reads its superclass before it defines the class, so
    # the superclass is never the class it heads.
    #: (String const, String qualifier, Hash[String, untyped] qualifiers, ?defining: String?) -> String?
    def resolve_constant(const, qualifier, qualifiers, defining: nil)
      parts = qualifier.split("::")
      parts.size.downto(0).map { |n| [*parts.first(n), const].join("::") }.find { |name| name != defining && qualifiers.key?(name) }
    end

    # The cap keeps the nearest callers; the kept names print sorted. A
    # caller of `new` reaches `initialize` in the call it writes, so that
    # hop adds no depth, and its callers go first in the queue.
    #: (String qualified, Array[edge] edges) -> Array[String]
    def upstream(qualified, edges)
      callers_by_depth(qualified, edges, UPSTREAM_DEPTH).sort_by { |name, depth| [depth, name] }.first(REACHABLE_CAP).map(&:first).sort
    end

    #: (String qualified, Array[edge] edges, Integer? limit) -> Hash[String, Integer]
    def callers_by_depth(qualified, edges, limit)
      reverse = callers_index(edges)
      depths = {} #: Hash[String, Integer]
      queue = reverse.fetch(qualified, []).uniq.map { |name| [name, 1] }
      until queue.empty?
        name, depth = queue.shift
        next if name == qualified || depths.key?(name)

        depths[name] = depth
        if name.end_with?("#initialize")
          reverse.fetch(name, []).each { |parent| queue.unshift([parent, depth]) unless depths.key?(parent) }
          next
        end
        next if limit && depth >= limit

        reverse.fetch(name, []).each { |parent| queue << [parent, depth + 1] unless depths.key?(parent) }
      end
      depths
    end

    #: (Array[edge] edges) -> Hash[String, Array[String]]
    def callers_index(edges)
      cache = @callers_index ||= Hash.new.compare_by_identity
      cache[edges] ||= edges.group_by { |edge| edge["to"] }.transform_values { |list| list.map { |edge| edge["from"] } }
    end

    #: (String base, String head) -> Array[String]
    def intent_lines(base, head)
      messages = @git.commit_messages(base, head).filter_map do |message|
        lines = message.lines.map(&:strip).reject(&:empty?)
        lines.empty? ? nil : lines
      end

      messages.flat_map.with_index { |lines, index| index.zero? ? lines : ["---", *lines] }
    end

    #: (doc item) -> doc
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
        "reached_by" => item["reached_by"],
        "caller_depths" => item["caller_depths"],
        "dynamic_callers" => item["dynamic_callers"],
        "builders" => item["builders"],
        "callbacks" => item["callbacks"],
        "run_by" => item["run_by"],
        "existing_tests" => item["existing_tests"],
        "entry_point_tests" => item["entry_point_tests"],
        "via_constant" => item["via_constant"],
        "forwards_to_added" => item["forwards_to_added"],
        "edits_only_raise" => item["edits_only_raise"],
        "moved_from" => item["moved_from"]
      }
    end

    #: (doc item) -> doc
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
        "read_by" => item["read_by"],
        "moved_from" => item["moved_from"]
      }
    end

    #: (String change, SourceIndex::Method? old_node, SourceIndex::Method? new_node) -> String
    def signature_of(change, old_node, new_node)
      return "added" if change == "added"
      return "removed" if change == "removed"

      old_node&.params == new_node&.params ? "same" : "changed"
    end

    #: (Array[doc] items, String prefix) -> void
    def assign_ids(items, prefix)
      items.sort_by! { |item| identity_sort(item) }
      width = [2, items.size.to_s.length].max
      items.each_with_index { |item, index| item["id"] = format("%s%0#{width}d", prefix, index + 1) }
    end

    #: (doc item) -> [String, String, String]
    def identity_sort(item)
      node = item["new"] || item["old"]
      [node.file, node.qualified, item["change"]]
    end

    #: (untyped node) -> [String, String]
    def identity(node)
      [node.file, node.qualified]
    end

    #: (Array[untyped] nodes) -> Hash[[String, String], untyped]
    def index_by(nodes)
      nodes.to_h { |node| [identity(node), node] }
    end

    #: (String? text) -> String
    def norm(text)
      text.to_s.rstrip
    end

    #: (String? text) -> String?
    def cap(text)
      Text.cap_lines(text)
    end
  end

  module CoverageFile
    module_function

    #: (String path) -> Array[doc]
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
          "lines" => test["lines"].is_a?(Hash) ? test["lines"] : {} #: Hash[String, untyped]
        }
      }.sort_by { |test| [test["file"], test["id"]] }
    rescue JSON::ParserError => err
      raise UsageError, "coverage file is not JSON: #{err.message}"
    end
  end
end
