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
    RECORD_BUILDERS = %w[create create! build].freeze
    # A value the source does not type, whether or not its name names a model.
    UNTYPED_RECEIVERS = %w[unknown named].freeze

    # The classes and modules head defines, after `build`.
    attr_reader :head_constants

    def self.between(repo, base_ref, head_ref, coverage: nil, setup: nil, databases: [])
      new(repo, base_ref, head_ref, coverage: coverage, setup: setup, databases: databases).build
    end

    # `setup` is the command `run --setup` runs in each checkout, and
    # `databases` the numbered test databases, base and head in turn.
    def initialize(repo, base_ref, head_ref, coverage: nil, setup: nil, databases: [])
      @git = repo.is_a?(GitRepo) ? repo : GitRepo.new(repo)
      @setup = setup
      @databases = databases
      @base_ref = base_ref
      @head_ref = head_ref
      @coverage = coverage.nil? ? nil : CoverageFile.load(coverage)
      @texts = {}
      @parsed = {}
      @test_names = {}
    end

    def build
      base = @git.base_rev(@base_ref)
      head = @git.rev(@head_ref)
      files = DiffParser.name_status(@git.name_status(base, head))
      hunks = index_hunks(DiffParser.parse(@git.diff(base, head)))
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
      decorate_dynamic_callers(methods, head_idx, base_idx)
      factories = factories_of(head_idx)
      builders = builders_for(methods, head_idx, factories)
      decorate_callbacks(methods, base_idx, head_idx, factories, head_edges, base_edges)
      decorate_tests(methods, base_idx, head_idx, builders)
      entrypoints = entrypoints_for(methods, head_idx, base_idx)

      {
        "version" => VERSION,
        "base" => base,
        "head" => head,
        "existing_tests_via" => @coverage ? "coverage" : "grep",
        "warnings" => warnings(base, head) + schema_warnings(head, files),
        "intent" => intent_lines(base, head),
        "files" => files,
        "dependencies" => dependencies(base, head),
        "parse_errors" => (base_idx["errors"] + head_idx["errors"]).sort_by { |err| [err["ref"], err["file"], err["message"]] },
        "constants" => constants.map { |item| constant_hash(item) },
        "methods" => methods.map { |item| method_hash(item) },
        "changed_lines" => changed_lines(hunks),
        "entrypoints" => entrypoints,
        "factories_skipped" => factories.select(&:reason).map { |factory| { "file" => factory.file, "line" => factory.line, "name" => factory.name, "reason" => factory.reason } }
      }
    end

    private

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

    # Rails keeps a schema in db/schema.rb or db/structure.sql, and a
    # second database's in db/<name>_schema.rb, beside db/<name>_migrate/.
    SCHEMA_FILE = %r{\Adb/(?:\w+_)?(?:schema\.rb|structure\.sql)\z|\Adb/(?:\w+_)?migrate/}
    TEST_HELPERS = %w[spec/rails_helper.rb spec/spec_helper.rb test/test_helper.rb].freeze

    # A test database made once from one schema holds neither side's after
    # a change to it, so a row can fail on a missing column and read as a
    # regression. A helper that calls maintain_test_schema! loads the
    # schema of the checkout it boots in; without one, only --setup can.
    def schema_warnings(head, files)
      changed = files.map { |file| file["file"] }.grep(SCHEMA_FILE).sort
      return [] if changed.empty?

      warning = "head changes the database schema (#{changed.join(", ")}), so each side's test database must hold that side's schema, " \
                "or a row can fail on the database and not on the code."
      return ["#{warning} `--setup` ran `#{@setup}` in each checkout before the candidates."] if @setup

      helpers = TEST_HELPERS.select { |path| @git.show(head, path) }
      return [warning] if helpers.empty? || helpers.any? { |path| @git.show(head, path).include?("maintain_test_schema!") }

      databases = @databases.each_slice(2).map { |base, head_db| "base #{base}, head #{head_db}" }
      into = databases.empty? ? "its own test database" : "its own test database (#{databases.join("; ")})"
      ["#{warning} #{helpers.join(" and ")} #{helpers.one? ? "does" : "do"} not call `ActiveRecord::Migration.maintain_test_schema!`, so no candidate loads either schema: " \
       "pass `--setup 'bin/rails db:create db:schema:load'` to `jitcatch run` to load each side's schema into #{into} before the candidates run."]
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

    # The head lines each Ruby file's hunks wrote, as inclusive ranges, so a
    # call on an edited line counts as changed code even outside any method.
    def changed_lines(hunks)
      hunks.filter_map { |path, file|
        ranges = file["hunks"].reject { |hunk| hunk["new_count"].zero? }.map { |hunk| [hunk["new_start"], hunk["new_start"] + hunk["new_count"] - 1] }
        [path, ranges] if file["new_path"] && ranges.any?
      }.sort.to_h
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
      superclasses = []
      calls = []
      private_constants = []
      hidden_new = []
      errors = []
      sources = {}
      indexes = {}
      listed = @git.ruby_blobs(sha).select { |blob| blob.size <= MAX_BLOB }
      @texts.merge!(@git.read_blobs(listed.map(&:oid).uniq - @texts.keys))
      listed.each do |blob|
        file = blob.path
        sources[file] = @texts.fetch(blob.oid)
        # A file both sides share is parsed once.
        index = (@parsed[[file, blob.oid]] ||= SourceIndex.parse(sources[file], file: file))
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
      { "methods" => methods, "constants" => constants, "namespaces" => namespaces, "superclasses" => superclasses, "calls" => calls, "hidden_new" => hidden_new, "errors" => errors, "sources" => sources, "indexes" => indexes }
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
      mark_moves(found, head_idx["methods"], hunks) { "moved" }
    end

    # A method that leaves one file while head defines the same name in
    # another is moved, not removed: it still answers a call. The other side
    # is read from every file, test files too, since a test double can move
    # into test/, where no change of its own is listed. A file the diff
    # touched is the likelier destination than an older copy elsewhere.
    # The block names the change a move is, from the old and the new node.
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
      # A constant that keeps its value in its new file is moved, and its
      # readers see nothing new; one whose value changed on the way is modified.
      mark_moves(found, head_idx["constants"], hunks) { |old_c, new_c| norm(value_of(old_c)) == norm(value_of(new_c)) ? "moved" : "modified" }
      found + changed_namespaces(base_idx, head_idx, hunks)
    end

    def value_of(const)
      const.source.sub(/A[^=]*=/, "").strip
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
    def mark_forwarders(methods, head_edges, hunks)
      added = methods.select { |method| method["change"] == "added" }.map { |method| method["new"].qualified }
      methods.each do |method|
        method["forwards_to_added"] = method["change"] == "modified" && added.any? && forwards?(method["new"], added, head_edges, hunks)
      end
    end

    def forwards?(node, added, head_edges, hunks)
      lines = []
      removed = 0
      hunks.fetch(node.file, { "hunks" => [] })["hunks"].each do |hunk|
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

    def controller_action?(name)
      owner, sep, = SourceIndex.split_qualified(name)
      sep == "#" && owner.split("::").last.to_s.end_with?("Controller")
    end

    def decorate_tests(methods, base_idx, head_idx, builders)
      test_sources = test_sources_for(base_idx, head_idx)
      public_names = (base_idx["methods"] + head_idx["methods"]).filter_map { |node| [node.qualified, true] if node.visibility == "public" }.to_h
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
          else
            merge_hits(call_hits(test_sources.keys, method["run_by"], "callback", base_idx, head_idx), grep_hits(test_sources, node.bare_name))
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

    # A test file that sends the endpoint's verb to a path ending in its
    # segments, as a request spec does.
    def request_hits(test_sources, bare)
      pattern = request_pattern(bare)
      test_sources.filter_map { |file, source| { "file" => file, "via" => "grep" } if source.match?(pattern) }
        .sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # `post "/v1/things/#{thing.id}/refresh"` for `POST /things/:id/refresh`:
    # any segments before the endpoint's, a `:param` matching any one.
    def request_pattern(bare)
      verb, path = bare.split(" ", 2)
      segment = %q{[^"'?/\s]+}
      parts = path.split("/").reject(&:empty?).map { |part| part.start_with?(":") ? segment : Regexp.escape(part) }
      Regexp.new(%Q{\\b#{verb.downcase}[\\s(]+["'](?:/#{segment})*/#{parts.join("/")}/?["'?]})
    end

    def grep_hits(test_sources, bare)
      return [] if bare.nil? || bare.length < 3

      pattern = /\b#{called(bare)}/
      test_sources.filter_map { |file, source|
        next unless source.match?(pattern)

        { "file" => file, "via" => "grep" }
      }.sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # A factory that builds a class no file defines may need an inflection
    # the app configures (`ApiKey` against `APIKey`), so it is not followed.
    # One that builds a Ruby value, as `class: Hash` does for the shape of an
    # API response, builds no class of the app, so nothing is skipped. The
    # list is fixed so that every Ruby prints the same document.
    RUBY_VALUE_CLASSES = %w[Array Data Hash Object OpenStruct Set String Struct].freeze

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
    def factory_mentions(qualifier, factories)
      factories.reject(&:reason).flat_map do |factory|
        traits = factory.trait_builds.select { |_trait, classes| classes.include?(qualifier) }.keys
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
    def app_calls(idx)
      idx["calls"].filter_map { |call|
        next if call.enclosing.nil? || test_file?(call.file)

        written = written_call(call)
        [written, call.enclosing] if written
      }
    end

    def written_call(call)
      qualifier, sep, _bare = SourceIndex.split_qualified(call.enclosing)
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
    def record_callbacks(idx)
      parents = lookups(idx)[3]
      idx["indexes"].reject { |path, _index| test_file?(path) }.values.flat_map(&:callbacks)
        .select { |callback| ancestry(callback.qualifier, parents).include?("ActiveRecord::Base") }
        .group_by { |callback| SourceIndex.qualify(callback.qualifier, callback.method, false) }
    end

    def callback_calls(callback, factories)
      calls = callback.calls.map { |call| "#{callback.qualifier}#{call}" }
      calls.include?("#{callback.qualifier}.create") ? calls + factory_mentions(callback.qualifier, factories) : calls
    end

    def constructor?(node)
      node.bare_name == "initialize" && node.kind == "instance" && !node.qualifier.empty?
    end

    # A test file that makes one of the calls, as its parsed source writes
    # it. `Loan.new` also names `Shop::Loan` from inside `Shop`.
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

    def merge_hits(builds, greps)
      built = builds.map { |hit| hit["file"] }
      (builds + greps.reject { |hit| built.include?(hit["file"]) }).sort_by { |hit| hit["file"] }.first(TEST_CAP)
    end

    # A method name can end in `!` or `?`, where `\b` cannot follow, and
    # `save` is not a call of `save!`.
    def called(bare)
      "#{Regexp.escape(bare)}(?![\\w?!])"
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

    def public_methods_of(idx, qualifier)
      idx["methods"].select { |method| method.qualifier == qualifier && method.visibility == "public" && !test_file?(method.file) }
    end

    def edges_for(idx)
      by_class, by_bare, qualifiers, parents = lookups(idx)
      edges = []
      named_owners = {}
      idx["calls"].each do |call|
        next if call.enclosing.nil? || test_file?(call.file)

        Array(call_target(call, by_class, by_bare, qualifiers, parents, named_owners)).each do |target|
          next if target.qualified == call.enclosing

          edges << { "from" => call.enclosing, "to" => target.qualified, "file" => call.file, "line" => call.line }
        end
      end
      edges.uniq { |edge| [edge["from"], edge["to"], edge["file"], edge["line"]] }
        .sort_by { |edge| [edge["file"], edge["line"], edge["from"], edge["to"]] }
    end

    def lookups(idx)
      methods = idx["methods"]
      by_class = methods.group_by { |method| [method.qualifier, method.bare_name] }
      by_bare = methods.group_by(&:bare_name)
      # A class with no method of its own still names a class to look up.
      qualifiers = idx["namespaces"].to_h { |node| [node.qualified, []] }.merge(methods.group_by(&:qualifier))
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
    def call_target(call, by_class, by_bare, qualifiers, parents, named_owners = {})
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
        key = [qualifier, receiver.const]
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

    def ancestry(owner, parents)
      chain = [owner]
      chain << parents[chain.last] while parents.key?(chain.last) && !chain.include?(parents[chain.last])
      chain
    end

    # Ruby looks a constant up from the innermost enclosing namespace out.
    # A class header reads its superclass before it defines the class, so
    # the superclass is never the class it heads.
    def resolve_constant(const, qualifier, qualifiers, defining: nil)
      parts = qualifier.split("::")
      parts.size.downto(0).map { |n| [*parts.first(n), const].join("::") }.find { |name| name != defining && qualifiers.key?(name) }
    end

    # The cap keeps the nearest callers; the kept names print sorted. A
    # caller of `new` reaches `initialize` in the call it writes, so that
    # hop adds no depth, and its callers go first in the queue.
    def upstream(qualified, edges)
      callers_by_depth(qualified, edges, UPSTREAM_DEPTH).sort_by { |name, depth| [depth, name] }.first(REACHABLE_CAP).map(&:first).sort
    end

    def callers_by_depth(qualified, edges, limit)
      reverse = callers_index(edges)
      depths = {}
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

    def callers_index(edges)
      (@callers_index ||= {}.compare_by_identity)[edges] ||= edges.group_by { |edge| edge["to"] }.transform_values { |list| list.map { |edge| edge["from"] } }
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
        "moved_from" => item["moved_from"]
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
        "readers" => item["readers"],
        "moved_from" => item["moved_from"]
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
