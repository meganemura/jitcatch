# frozen_string_literal: true

require "prism"

module JitCatch
  # Lists, for each value a change edits in a Rails app, the code at head
  # that reads that value without calling it by name: a route helper that
  # reaches `to_param`, a `send` of a literal name, a callback, a scope, a
  # constant in SQL, a template, a validation, a setting. Each row says how
  # it reads the value, why that matters, and what a test would check.
  #
  # It reads source only: Prism over `app/`, `config/`, `lib/`,
  # `db/schema.rb`, and ERB templates turned into Ruby line for line. It
  # names an object's model by its variable or method name, so a reader
  # whose receiver has an unrelated name is not listed (BLIND).
  class Readers
    # A value the change edits. `kind` is one of the RULES keys, `owner` the
    # class as its own file names it (the table's model, for a schema default),
    # which is how code elsewhere names it too, and `scope` the full name
    # with its enclosing modules. `line` and `last_line` are the lines it is
    # declared on, `state` is added, modified, or removed, and `node` is its
    # declaration (the default value, for a default).
    Value = Data.define(:kind, :owner, :scope, :name, :file, :line, :last_line, :state, :node) do
      def label
        case kind
        when :constant then "#{scope}::#{name}"
        when :attribute_default then "#{owner}.#{name} default"
        when :method then "#{scope}##{name}"
        else "#{scope}.#{name}"
        end
      end
    end
    Row = Data.define(:value, :file, :line, :mechanism, :why, :score, :rank, :test, :group, :also, :edited)
    Source = Data.define(:path, :tree, :template)
    # How strongly a mechanism points at a test, the reason that ranks it,
    # and the test sentence, with `%<where>s` and the other fields a rule
    # fills in.
    Mechanism = Data.define(:score, :rank, :test)

    BLIND = [
      "receivers named unlike their model (`x = Branch.first; link_to x`)",
      "dispatch names built at run time from data outside the source (a DB column, a request param)",
      "routes drawn by `draw`, loops, or concerns; `to_param` reached through a gem's helper",
      "serializers, jbuilder, and other template languages than ERB",
      "callbacks and validations added by concerns or gems",
      "config read through ENV or a YAML file at boot"
    ].freeze

    DISPATCH = %i[send public_send __send__ try try! method public_method respond_to? instance_method].freeze
    SQL_CALLS = %i[where order reorder select joins group having pluck find_by_sql exec_query execute from not count_by_sql].freeze
    QUERY_CALLS = %i[all find find_by find_by! where first last take count exists? pluck order includes find_each].freeze
    CALLBACKS = /\A(before|after|around)_(validation|save|create|update|destroy|commit|initialize|find|touch)\z|\Aafter_(create|update|destroy|save)_commit\z/
    VALIDATIONS = %i[validates validate validates_presence_of validates_uniqueness_of validates_inclusion_of].freeze
    SQL_TEXT = /\b(SELECT|UPDATE|DELETE|INSERT|WHERE|JOIN)\b/
    SCHEMA = "db/schema.rb"
    READ_ROOTS = %w[app/ config/ lib/].freeze

    MECHANISMS = {
      route_param_mismatch: Mechanism.new(100, "the URL value and the lookup now disagree",
        "Render %<where>s with a %<model>s whose to_param differs from its id, follow the URL %<helper>s builds, and check %<action>s finds that same %<model>s."),
      route_param: Mechanism.new(70, "a URL carries to_param into a lookup",
        "Render %<where>s, follow the URL %<helper>s builds for a %<model>s, and check %<action>s finds that same %<model>s."),
      param_lookup: Mechanism.new(65, "an action turns a param back into a record",
        "Request %<action>s with the param a %<model>s's to_param gives and check it finds that %<model>s."),
      polymorphic_route: Mechanism.new(75, "a URL or partial path comes from the model",
        "Render or request %<where>s with a %<model>s and check the URL or partial %<call>s builds from its model_name."),
      json_render: Mechanism.new(85, "a response body serializes it", "Request %<where>s and check the JSON body it renders for a %<model>s."),
      to_s_output: Mechanism.new(60, "a page prints it", "Render %<where>s with a %<model>s and check the text it prints for it."),
      dispatch_literal: Mechanism.new(90, "a literal name dispatches to it",
        "Run %<where>s so it dispatches :%<name>s and check the value it gets back from %<owner>s#%<name>s."),
      dispatch_pattern: Mechanism.new(75, "a built name can reach it", "Run %<where>s with the input that builds the name %<name>s and check the value it gets back."),
      dispatch_dynamic: Mechanism.new(70, "a computed dispatch on the owner can reach it",
        "Run %<where>s with :%<name>s as the name it computes and check the value it gets back from %<owner>s."),
      dispatch_name_source: Mechanism.new(55, "the name is written here, the dispatch is elsewhere",
        "Run the path from %<where>s, where :%<name>s is written, to a dispatch on a %<owner>s, and check the value it gets back."),
      callback: Mechanism.new(85, "Rails runs it on save", "Save a %<owner>s through %<where>s and check the attribute or record this callback sets."),
      validation_reads: Mechanism.new(80, "a validation reads it on save", "Save a %<owner>s at the edge %<where>s checks and check whether it is valid."),
      default_taker: Mechanism.new(85, "a record is created with the default", "Create a %<owner>s through %<where>s and check the %<name>s it is saved with."),
      attribute_read: Mechanism.new(60, "a method reads the default", "Build a %<owner>s with %<name>s left at its default and check what %<where>s returns."),
      attribute_guard: Mechanism.new(80, "a callback fills it when unset", "Build a %<owner>s with %<name>s unset and check the value %<where>s leaves in it."),
      sql_constant: Mechanism.new(90, "a query reads it, so returned rows change",
        "Run the query at %<where>s and check which rows it returns now that %<name>s feeds it."),
      scope_call: Mechanism.new(60, "a caller uses the scope", "Run %<where>s against records on both sides of the %<name>s scope and check which ones it returns."),
      default_scope_query: Mechanism.new(50, "a query runs under the default scope", "Run the query at %<where>s and check which %<owner>s rows and order it returns."),
      default_scope_first: Mechanism.new(80, "first/last picks by the default order", "Run %<where>s with two %<owner>s rows and check which one first/last picks."),
      default_scope_order: Mechanism.new(80, "an order is added after the default order",
        "Run %<where>s with two %<owner>s rows that tie on its own order and check the order it returns."),
      default_scope_association: Mechanism.new(65, "an association loads under the default scope",
        "Load %<where>s through the association and check which %<owner>s rows it holds."),
      config_read: Mechanism.new(85, "code reads the setting", "Run %<where>s with the app's config and check the value it derives from %<name>s."),
      constant_read: Mechanism.new(45, "code reads it, effect not classified", "Run %<where>s and check the value it derives from %<name>s."),
      template_call: Mechanism.new(55, "a page prints it", "Render %<where>s and check the text it prints from %<name>s."),
      save_site: Mechanism.new(40, "a save runs it", "Save a %<owner>s through %<where>s and check the callbacks and validations it runs.")
    }.freeze

    # The rules a method's name adds to the ones every method gets.
    SPECIAL = {
      "to_param" => %i[route_rows polymorphic_rows param_lookup_rows],
      "model_name" => %i[polymorphic_rows],
      "as_json" => %i[json_rows],
      "serializable_hash" => %i[json_rows],
      "to_json" => %i[json_rows],
      "to_s" => %i[to_s_rows]
    }.freeze

    # The rules each kind of changed value has.
    RULES = {
      method: ->(r, v) { SPECIAL.fetch(v.name, []).flat_map { |rule| r.send(rule, v) } + r.dispatch_rows(v) + r.template_rows(v) },
      scope: ->(r, v) { r.scope_rows(v) },
      default_scope: ->(r, v) { r.default_scope_rows(v) },
      constant: ->(r, v) { r.constant_rows(v) },
      attribute_default: ->(r, v) { r.attribute_rows(v) },
      config: ->(r, v) { r.config_rows(v) },
      callback: ->(r, v) { r.save_rows(v) },
      validation: ->(r, v) { r.save_rows(v) }
    }.freeze

    # `head_sources` and `base_sources` map a path to its text on each side;
    # `diff` is every file's hunks, as `DiffParser.parse` gives them.
    def self.between(base_sources:, head_sources:, diff:, routes:, inflections:)
      new(base_sources, head_sources, diff, routes, inflections).found
    end

    def initialize(base_sources, head_sources, diff, routes, inflections)
      @base_sources = base_sources
      @head_sources = head_sources
      @lines = changed_lines(diff)
      @routes = routes
      @inflections = inflections
      @sources = head_sources.filter_map do |path, text|
        next unless path == SCHEMA || READ_ROOTS.any? { |root| path.start_with?(root) }
        next unless path.end_with?(".rb") || Template.template?(path)

        template = Template.template?(path)
        result = Prism.parse(template ? Template.as_ruby(text) : text)
        Source.new(path: path, tree: result.value, template: template) if result.success?
      end.sort_by(&:path)
      @models = @sources.select { |src| src.path.start_with?("app/models/") }.flat_map do |src|
        found = []
        each_node(src.tree) { |node, _| found << node.constant_path.slice if node.is_a?(Prism::ClassNode) }
        found
      end
      @names = model_names
      @suffixes = @names.keys.sort_by { |name| -name.size }
      constant_table
    end

    # The values the change edits and the rows that read them, highest
    # score first.
    def found
      values = changed_values
      rows = values.flat_map { |value| RULES.fetch(value.kind).call(self, value) }
      rows = rows.reject { |row| row.file == row.value.file && row.line == row.value.line }
      rows = rows.uniq { |row| [row.file, row.line, row.mechanism, row.value.name] }
      # The lookup a route row already names is that row's other end.
      cited = rows.flat_map { |row| row.why.scan(%r{(app/\S+:\d+)\)}).flatten.map { |place| "#{row.value.name} #{place}" } }
      rows = rows.reject { |row| row.mechanism == :param_lookup && cited.include?("#{row.value.name} #{row.file}:#{row.line}") }
      rows = rows.sort_by { |row| [-row.score, row.file, row.line] }
      rows = rows.group_by { |row| [row.value, row.mechanism, row.group] }.values.map do |same|
        same.first.with(also: same.drop(1).map { |row| "#{row.file}:#{row.line}" })
      end
      rows = rows.map { |row| row.with(edited: @lines.dig(row.file, :new).to_a.include?(row.line)) }
      [values, rows.sort_by { |row| [-row.score, row.file, row.line] }]
    end

    # The lines each file's hunks cover, on the base side and the head side.
    def changed_lines(diff)
      lines = {}
      diff.each do |file|
        [["old_path", :old, "old"], ["new_path", :new, "new"]].each do |path_key, side, prefix|
          path = file[path_key] or next
          covered = (lines[path] ||= { old: [], new: [] })[side]
          file["hunks"].each { |hunk| covered.concat((hunk["#{prefix}_start"]...(hunk["#{prefix}_start"] + hunk["#{prefix}_count"])).to_a) }
        end
      end
      lines
    end

    def changed_values
      @lines.keys.select { |path| path.end_with?(".rb") }.sort.flat_map do |path|
        lines = @lines[path]
        old_values = declarations(path, @base_sources[path])
        new_values = declarations(path, @head_sources[path])
        key = ->(value) { [value.kind, value.owner, value.name] }
        old_keys = old_values.map(&key)
        new_keys = new_values.map(&key)
        touched = ->(value, set) { (value.line..value.last_line).any? { |line| set.include?(line) } }
        found = new_values.select { |value| touched.(value, lines[:new]) }.map do |value|
          value.with(state: old_keys.include?(key.(value)) ? :modified : :added)
        end
        found += old_values.select { |value| touched.(value, lines[:old]) && !new_keys.include?(key.(value)) }.map { |value| value.with(state: :removed) }
        found.uniq { |value| [value.kind, value.owner, value.name, value.state] }
      end
    end

    # The values a file declares, with no state yet: methods, scopes,
    # default scopes, constants, callbacks, validations, attributes, schema
    # column defaults, and config assignments.
    def declarations(path, source)
      return [] unless source

      result = Prism.parse(source)
      return [] unless result.success?

      values = []
      table = nil
      each_node(result.value) do |node, stack|
        next unless node.is_a?(Prism::DefNode) || node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::CallNode)

        owner = enclosing_class(stack)
        scope = nesting(stack).last
        declare = lambda do |kind, of, name, declared = node|
          values << Value.new(kind: kind, owner: of, scope: of == owner ? scope : of, name: name, file: path,
            line: node.location.start_line, last_line: node.location.end_line, state: nil, node: declared)
        end
        case node
        when Prism::DefNode
          declare.(:method, owner, node.name.to_s)
        when Prism::ConstantWriteNode
          declare.(:constant, scope, node.name.to_s)
        when Prism::CallNode
          args = arguments(node)
          name = node.name
          if path == SCHEMA && name == :create_table
            table = literal_name(args.first)
          elsif path == SCHEMA && node.receiver&.slice == "t" && table && (default = keywords(args)["default"])
            declare.(:attribute_default, model_of_table(table), literal_name(args.first), default)
          elsif node.receiver.nil? && owner && stack.none?(Prism::DefNode)
            case name
            when :scope then declare.(:scope, owner, literal_name(args.first))
            when :default_scope then declare.(:default_scope, owner, "default_scope")
            when :attribute then declare.(:attribute_default, owner, literal_name(args.first)) if keywords(args)["default"]
            when CALLBACKS then declare.(:callback, owner, "#{name} #{args.filter_map { |arg| literal_name(arg) }.join(",")}")
            when *VALIDATIONS then declare.(:validation, owner, args.filter_map { |arg| literal_name(arg) }.join(","))
            end
          elsif path.start_with?("config/") && name.to_s.end_with?("=") && node.receiver&.slice&.match?(/(\A|\.)config(\.|\z)/)
            setting = [node.receiver.slice.sub(/\A(.*\.)?config\.?/, ""), name.to_s.delete_suffix("=")].reject(&:empty?).join(".")
            declare.(:config, "config", setting)
          end
        end
      end
      values
    end

    private :changed_lines, :changed_values, :declarations

    # Each rule below takes a Value and returns the Rows that read it.

    # Actions that turn a param back into the model, whoever built the URL.
    def param_lookup_rows(value)
      one = snake(value.owner)
      rows = []
      @sources.select { |src| src.path.start_with?("app/controllers/") }.each do |src|
        each_node(src.tree) do |node, stack|
          next unless params_read?(node)

          key = literal_name(arguments(node).first)
          user = stack.reverse.find { |up| up.is_a?(Prism::CallNode) && %i[find find_by find_by! where].include?(up.name) }
          next unless user && key

          on_model = user.receiver&.slice == value.owner
          next unless key == "#{one}_id" || (on_model && key == "id")

          action = enclosing_def(stack)
          controller = src.path.delete_prefix("app/controllers/").delete_suffix(".rb").split("/").map { |part| @inflections.camelize(part) }.join("::")
          rows << row(value, src, node, :param_lookup, "#{user.slice[0, 60]} in #{action} turns params[:#{key}] back into a #{value.owner} by id",
            action: "#{controller}##{action}")
        end
      end
      rows
    end

    def route_rows(value)
      rows = []
      returns = param_source(value)
      each_call do |src, node, _|
        route = @routes.route_for_helper(node.name.to_s) or next

        args = arguments(node)
        segments = route.path.scan(/:(\w+)/).flatten
        pairs = args.reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.each_with_index.map { |arg, i| [segments[i], arg] }
        pairs += keywords(args).to_a
        pairs.each do |key, arg|
          model, = model_of(arg)
          next unless key && model == value.owner

          found = action_def(route.action)
          lookup = found ? param_lookups(found[1], key) : []
          by_id = lookup.select { |_, by, _| by == "id" || by.end_with?("_id") }
          mismatch = !id_param?(returns) && by_id.any?
          detail = lookup.map { |line, by, text| "#{route.action} reads params[:#{key}] by #{by} (#{text}, #{found[0].path}:#{line})" }.join("; ")
          why = "#{arg.slice} goes through #{value.owner}#to_param (now `#{returns}`) into params[:#{key}]; " +
            (detail.empty? ? "#{route.action} does not read it in its own body" : detail)
          rows << row(value, src, node, mismatch ? :route_param_mismatch : :route_param, why, helper: node.slice[0, 60], action: route.action,
            group: "#{route.action} #{key}")
        end
      end
      rows
    end

    def polymorphic_rows(value)
      rows = []
      each_call do |src, node, _|
        args = arguments(node)
        targets = case node.name
        when :link_to, :button_to then args[1..] || []
        when :redirect_to, :url_for, :polymorphic_path, :polymorphic_url, :render, :form_for then args.first(1)
        when :form_with then [keywords(args)["model"]].compact
        else []
        end
        json = keywords(args)["json"] if node.name == :render
        targets += [json] if json
        targets.each do |arg|
          next if arg.is_a?(Prism::KeywordHashNode)

          model, = model_of(arg)
          next unless model == value.owner

          if json.equal?(arg)
            rows << row(value, src, node, :json_render, "render json: #{arg.slice} serializes it through #{value.owner}#as_json")
          elsif value.name == "model_name" || value.name == "to_param"
            rows << row(value, src, node, :polymorphic_route, "#{node.name} #{arg.slice} builds a URL or partial path from #{value.owner}##{value.name}", call: node.name)
          end
        end
      end
      rows
    end

    def to_s_rows(value)
      rows = []
      @sources.each do |src|
        each_node(src.tree) do |node, _|
          arg = case node
          when Prism::EmbeddedStatementsNode then node.statements&.body&.last
          when Prism::CallNode
            arguments(node).first if node.name == Template::OUTPUT || %i[link_to button_to].include?(node.name)
          end
          next unless arg

          model, many = model_of(arg)
          next unless model == value.owner && many == :one

          via = if node.is_a?(Prism::EmbeddedStatementsNode) then "interpolates"
          elsif node.name == Template::OUTPUT then "prints"
          else "uses as link text"
          end
          rows << row(value, src, node, :to_s_output, "#{via} #{arg.slice}, which calls #{value.owner}#to_s")
        end
      end
      rows
    end

    def json_rows(value)
      rows = polymorphic_rows(value).select { |found| found.mechanism == :json_render }
      each_call do |src, node, _|
        next unless %i[to_json as_json].include?(node.name) && node.receiver

        model, = model_of(node.receiver)
        rows << row(value, src, node, :json_render, "#{node.slice[0, 50]} serializes it through #{value.owner}#as_json") if model == value.owner
      end
      rows
    end

    # A name a dispatch can reach: a literal, or an interpolation whose fixed
    # parts match it.
    def dispatch_rows(value)
      name = value.name
      rows = []
      dynamic = []
      each_call do |src, node, stack|
        args = arguments(node)
        first = args.first
        if DISPATCH.include?(node.name) && first
          if literal_name(first) == name
            rows << row(value, src, node, :dispatch_literal, "#{node.slice[0, 60]} dispatches to #{name} by a literal name")
          elsif first.is_a?(Prism::InterpolatedSymbolNode) || first.is_a?(Prism::InterpolatedStringNode)
            pattern = first.parts.map { |part| part.is_a?(Prism::StringNode) ? Regexp.escape(part.unescaped) : ".+" }.join
            rows << row(value, src, node, :dispatch_pattern, "#{node.slice[0, 60]} builds a name that matches #{name}") if name.match?(/\A#{pattern}\z/)
          else
            dynamic << [src, node] unless dispatch_on_other_model?(value, node, stack)
          end
        elsif (node.name.match?(CALLBACKS) || VALIDATIONS.include?(node.name) || %i[delegate alias_method].include?(node.name)) &&
            node.receiver.nil? && (args.any? { |arg| literal_name(arg) == name } || keywords(args).values_at("if", "unless").any? { |arg| literal_name(arg) == name })
          mechanism = VALIDATIONS.include?(node.name) ? :validation_reads : :callback
          rows << row(value, src, node, mechanism, "#{node.slice[0, 60]} names :#{name}, so Rails calls it")
        end
      end
      rows + computed_dispatch_rows(value, dynamic)
    end

    def template_rows(value)
      rows = []
      @sources.select(&:template).each do |src|
        each_node(src.tree) do |node, _|
          next unless node.is_a?(Prism::CallNode) && node.name.to_s == value.name && node.receiver

          model, = model_of(node.receiver)
          next if model && model != value.owner

          rows << row(value, src, node, :template_call, "the template calls #{node.slice[0, 50]}" + (model ? "" : " (receiver's model not known by name)"))
        end
      end
      rows
    end

    def attribute_rows(value)
      attr = value.name
      owner = value.owner
      model_src = @sources.find { |src| src.path == "app/models/#{underscore_path(owner)}.rb" }
      return [] unless model_src

      rows = []
      defs = {}
      each_node(model_src.tree) { |node, _| defs[node.name.to_s] = node if node.is_a?(Prism::DefNode) }
      reads = ->(node) { node && node.slice.match?(/\b#{Regexp.escape(attr)}\b/) }
      each_node(model_src.tree) do |node, stack|
        next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && stack.none?(Prism::DefNode)

        args = arguments(node)
        if node.name.match?(CALLBACKS)
          targets = args.filter_map { |arg| literal_name(arg) }.filter_map { |target| defs[target] }
          hit = reads.(node.block) || targets.find { |target| reads.(target) }
          next unless hit

          guard = (hit.is_a?(Prism::DefNode) ? hit : node).slice.match?(/#{Regexp.escape(attr)}\s*\|\|=/)
          rows << row(value, model_src, node, guard ? :attribute_guard : :callback,
            "#{node.name} #{guard ? "fills" : "reads"} #{attr}" + (hit.is_a?(Prism::DefNode) ? " in #{hit.name} (line #{hit.location.start_line})" : ""))
        elsif VALIDATIONS.include?(node.name)
          target = args.filter_map { |arg| literal_name(arg) }
          hit = target.include?(attr) || target.filter_map { |name| defs[name] }.any? { |method| reads.(method) }
          rows << row(value, model_src, node, :validation_reads, "#{node.slice[0, 60]} checks #{attr}") if hit
        elsif node.name == :scope && reads.(node)
          rows << row(value, model_src, node, :scope_call, "scope #{literal_name(args.first)} filters on #{attr}", name: literal_name(args.first))
        end
      end
      defs.each_value do |method|
        next unless method.body&.slice&.match?(/(?<![.\w])#{Regexp.escape(attr)}\b(?!\s*=[^=])/)

        rows << row(value, model_src, method, :attribute_read, "#{owner}##{method.name} reads #{attr}", name: attr)
      end
      rows + default_taker_rows(value, owner, attr)
    end

    def constant_rows(value)
      rows = []
      name = value.name
      full = [value.owner, name].compact.join("::")
      @references ||= @sources.flat_map do |src|
        found = []
        each_node(src.tree) do |node, stack|
          if node.is_a?(Prism::ConstantPathNode) || (node.is_a?(Prism::ConstantReadNode) && !stack.last.is_a?(Prism::ConstantPathNode))
            found << [src, node, stack.dup]
          end
        end
        found
      end
      @references.each do |src, node, stack|
        next unless (node.is_a?(Prism::ConstantReadNode) ? node.name.to_s : path_name(node)) == name
        next if src.path == value.file && stack.any?(Prism::ConstantWriteNode)

        # A bare `STATUSES` in a class that defines its own is not this value.
        target = resolve(node, nesting(stack), full)
        next if target && target != full

        rows << ranked_constant(constant_row(value, src, node, stack), node, target)
      end
      rows
    end

    def config_rows(value)
      path = value.name
      rows = []
      each_call do |src, node, _|
        text = node.slice
        next if src.path == value.file || node.receiver.nil?
        next unless node.name.to_s == path.split(".").last && text.match?(/(Rails\.(application\.)?config(uration)?|config)\.#{Regexp.escape(path)}\z/)

        rows << row(value, src, node, :config_read, "reads #{text}")
      end
      rows
    end

    def scope_rows(value)
      rows = []
      each_call do |src, node, _|
        next unless node.name.to_s == value.name && node.receiver

        rows << row(value, src, node, :scope_call, "#{node.slice[0, 60]} calls the scope #{value.name}, which is not a def")
      end
      rows + dispatch_rows(value)
    end

    def default_scope_rows(value)
      rows = []
      owner = value.owner
      # The receiver a chain starts from: `Loan` in `Loan.overdue.order(:x)`.
      root = lambda do |node|
        node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
        node
      end
      on_owner = lambda do |node|
        start = root.(node)
        start.slice == owner || model_of(start)&.then { |model, many| model == owner && many == :many }
      end
      each_call do |src, node, stack|
        parent = stack.last
        next if parent.is_a?(Prism::CallNode) && parent.receiver.equal?(node) && (QUERY_CALLS + %i[includes order reorder limit]).include?(parent.name)

        if %i[order first last take].include?(node.name) && node.receiver && on_owner.(node.receiver) && (chain = node.slice).match?(/\.(order|first|last|take)\b/)
          orders = chain.scan(/\.(order|reorder|first|last|take)\b/).flatten
          next if orders.include?("reorder")

          mechanism = node.name == :order || orders.include?("order") ? :default_scope_order : :default_scope_first
          why = mechanism == :default_scope_order ? "#{chain[0, 70]} adds its order after the one the default scope sets" : "#{chain[0, 70]} picks by the order the default scope sets"
          rows << row(value, src, node, mechanism, why)
        elsif node.receiver&.slice == owner && QUERY_CALLS.include?(node.name)
          mechanism = %i[first last take].include?(node.name) ? :default_scope_first : :default_scope_query
          rows << row(value, src, node, mechanism, "#{node.slice[0, 60]} queries #{owner} under its default scope")
        elsif node.receiver&.slice == owner && node.name == :unscoped
          rows << row(value, src, node, :default_scope_query, "#{node.slice[0, 60]} drops the default scope")
        elsif node.receiver.nil? && %i[has_many has_one].include?(node.name)
          args = arguments(node)
          assoc = literal_name(args.first)
          target = literal_name(keywords(args)["class_name"]) || (assoc && @names[assoc]&.first)
          rows << row(value, src, node, :default_scope_association, "#{node.slice[0, 60]} loads #{owner} rows under its default scope") if target == owner && assoc
        elsif %i[first last take].include?(node.name) && node.receiver.is_a?(Prism::CallNode) &&
            @names[node.receiver.name.to_s]&.then { |model, many| model == owner && many == :many }
          rows << row(value, src, node, :default_scope_first, "#{node.slice[0, 60]} picks by the order the default scope sets")
        end
      end
      rows
    end

    def save_rows(value)
      rows = []
      each_call do |src, node, _|
        next unless %i[create create! save save! update update!].include?(node.name)

        model = node.receiver&.slice == value.owner ? value.owner : model_of(node.receiver)&.first
        next unless model == value.owner

        rows << row(value, src, node, :save_site, "#{node.slice[0, 60]} saves a #{value.owner}, which runs the #{value.kind}")
      end
      rows
    end

    private

    def row(value, src, node, mechanism, why, group: nil, **fields)
      kind = MECHANISMS.fetch(mechanism)
      where = "#{src.path}:#{node.location.start_line}"
      sentence = src.template ? kind.test : kind.test.sub(/\ARender (or request )?/, "Run ")
      test = format(sentence, { where: where, model: value.owner, owner: value.owner, name: value.name, helper: "", action: "", call: "" }.merge(fields))
      Row.new(value: value, file: src.path, line: node.location.start_line, mechanism: mechanism, why: why, score: kind.score, rank: kind.rank,
        test: test, group: group || where, also: [], edited: false)
    end

    # A dispatch on another known model cannot reach this owner.
    def dispatch_on_other_model?(value, node, stack)
      receiver = node.receiver
      if receiver.nil?
        (klass = enclosing_class(stack)) && klass != value.owner
      elsif receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        receiver.slice != value.owner
      else
        (model = model_of(receiver)&.first) && model != value.owner
      end
    end

    # A symbol or string spelled like the method, in code that also
    # dispatches by a name it computes. Only a name kept in a list
    # (`%w[late lost]`, a constant's array or hash) counts as one a computed
    # dispatch iterates; a lone "late" passed as a column value is data.
    def computed_dispatch_rows(value, dynamic)
      name = value.name
      sources = []
      unless dynamic.empty?
        @sources.each do |src|
          next if src.path == SCHEMA || src.path.start_with?("config/")

          each_node(src.tree) do |node, stack|
            next unless (node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)) && literal_name(node) == name
            next unless stack.last.is_a?(Prism::ArrayNode) || (stack.any?(Prism::ConstantWriteNode) && stack.any?(Prism::HashNode))

            sources << [src, node]
          end
        end
      end
      on_owner = dynamic.select do |_, node|
        node.receiver && (node.receiver.slice == value.owner || model_of(node.receiver)&.first == value.owner)
      end
      rows = []
      unless sources.empty?
        listed = sources.map { |src, node| "#{src.path}:#{node.location.start_line}" }.join(", ")
        on_owner.each do |src, node|
          rows << row(value, src, node, :dispatch_dynamic, "#{node.slice[0, 60]} dispatches on a #{value.owner} by a computed name; :#{name} is listed at #{listed}")
        end
      end
      near_sites = on_owner.empty? ? dynamic : on_owner
      return rows if near_sites.empty?

      dispatch_files = near_sites.map { |src, _| src.path }.uniq
      sources.each do |src, node|
        near = near_sites.find { |site, _| site.path == src.path } || near_sites.first
        rows << row(value, src, node, :dispatch_name_source,
          "#{node.slice} is written here; #{near[0].path}:#{near[1].location.start_line} dispatches by a computed name (#{near[1].slice[0, 50]})" +
          (dispatch_files.include?(src.path) ? "" : " in another file"))
      end
      rows
    end

    # Where a record is made without naming the attribute, the default is
    # the value it gets.
    def default_taker_rows(value, owner, attr)
      many = plural(snake(owner))
      rows = []
      each_call do |src, node, _|
        next unless %i[create create! new find_or_initialize_by find_or_create_by find_or_create_by! build].include?(node.name)

        receiver = node.receiver&.slice.to_s
        last = receiver.split(".").last
        next unless receiver == owner || receiver.end_with?(".#{many}") || receiver == many || (@names[last]&.first == owner && last == many)
        next if arguments(node).any? { |arg| keywords([arg]).key?(attr) } || node.slice.match?(/\b#{Regexp.escape(attr)}\s*[:=]/)

        rows << row(value, src, node, :default_taker, "#{node.slice[0, 60]} makes a #{owner} without setting #{attr}", name: attr)
      end
      rows
    end

    def constant_row(value, src, node, stack)
      name = value.name
      sql = stack.reverse.find { |up| up.is_a?(Prism::CallNode) && SQL_CALLS.include?(up.name) && query?(up) }
      string = stack.reverse.find { |up| up.is_a?(Prism::InterpolatedStringNode) || up.is_a?(Prism::InterpolatedXStringNode) }
      sql_text = string && !sql && string.parts.any? { |part| part.is_a?(Prism::StringNode) && part.unescaped.match?(SQL_TEXT) }
      validation = stack.find { |up| up.is_a?(Prism::CallNode) && VALIDATIONS.include?(up.name) }
      if sql || sql_text
        row(value, src, node, :sql_constant, sql_text ? "#{name} is interpolated into SQL text" : "#{name} is #{string ? "interpolated into" : "passed to"} the SQL of #{sql.name}")
      elsif validation
        row(value, src, validation, :validation_reads, "#{validation.slice[0, 60]} reads #{name}", owner: enclosing_class(stack) || value.owner)
      elsif src.template
        row(value, src, node, :template_call, "the template reads #{node.slice}")
      elsif src.path.start_with?("config/")
        row(value, src, node, :config_read, "reads #{node.slice} set in #{value.file}")
      else
        row(value, src, node, :constant_read, "reads #{node.slice}")
      end
    end

    # `Order.where`, `orders.where`, a bare `where` in a scope: a query.
    # `f.select` on a form builder is not.
    def query?(call)
      root = call
      root = root.receiver while root.is_a?(Prism::CallNode) && root.receiver
      root.equal?(call) || root.is_a?(Prism::ConstantReadNode) || root.is_a?(Prism::ConstantPathNode) ||
        root.is_a?(Prism::SelfNode) || model_of(root)&.last == :many
    end

    # A reference that names its owner from a file the change does not touch
    # is a reader nobody looked at; one that resolves to nothing visible may
    # come through a gem or a concern the index cannot see. A read beside the
    # edit, in a file the change touches, was in front of its author; a query
    # there still changes which rows come back, so it keeps its score.
    def ranked_constant(row, node, target)
      in_diff = @lines.key?(row.file)
      if target.nil?
        row.with(score: [row.score, 30].min, rank: "bare #{node.slice} is defined nowhere visible; may reach it through a mixin")
      elsif node.is_a?(Prism::ConstantPathNode) && !in_diff
        row.score >= 80 ? row.with(rank: "#{row.rank}; qualified, outside the diff") : row.with(score: 80, rank: "qualified #{node.slice} from a file outside the diff")
      elsif in_diff && row.mechanism != :sql_constant
        row.with(score: row.score - 10, rank: "#{row.rank}; in a file the change edits")
      else
        row
      end
    end

    # What a `to_param` body returns, when it is one attribute: `code`,
    # `"#{id}-#{name}"`, or `id`.
    def param_source(value)
      body = value.node.is_a?(Prism::DefNode) && value.node.body
      return "the default id" if value.state == :removed || !body

      (body.is_a?(Prism::StatementsNode) ? body.body.last : body).slice
    end

    def id_param?(text) = text.match?(/\A(id|id\.to_s|super|the default id)\z/)

    # How an action reads one param: `find(params[:id])`, `find_by(id: ...)`,
    # `where(branch_id: ...)` compare it to an id; `find_by(code: ...)` does not.
    def param_lookups(action_nodes, key)
      found = []
      action_nodes.each do |action_node|
        each_node(action_node) do |node, stack|
          next unless params_read?(node) && literal_name(arguments(node).first) == key

          user = stack.reverse.find { |up| up.is_a?(Prism::CallNode) && %i[find find_by find_by! where find_or_create_by].include?(up.name) }
          by = if user.nil? then "used as given"
          elsif user.name == :find then "id"
          else
            assoc = stack.reverse.find { |up| up.is_a?(Prism::AssocNode) }
            assoc ? literal_name(assoc.key).to_s : "id"
          end
          found << [node.location.start_line, by, user&.slice&.slice(0, 60) || node.slice]
        end
      end
      found
    end

    def params_read?(node)
      node.is_a?(Prism::CallNode) && node.name == :[] && node.receiver&.slice&.end_with?("params")
    end

    # The controller file of a route's action, and the nodes that run for
    # it: the action's def and its before_action filters. A filter's
    # `only:`/`except:` is not read, so every filter counts.
    def action_def(action)
      controller, name = action.split("#")
      src = @sources.find { |source| source.path == "app/controllers/#{underscore_path(controller)}.rb" } or return

      defs = {}
      filters = []
      each_node(src.tree) do |node, stack|
        defs[node.name.to_s] ||= node if node.is_a?(Prism::DefNode)
        next unless node.is_a?(Prism::CallNode) && node.name == :before_action && node.receiver.nil? && stack.none?(Prism::DefNode)

        filters.concat(arguments(node).filter_map { |arg| literal_name(arg) })
      end
      return unless defs[name]

      [src, [defs[name], *filters.filter_map { |filter| defs[filter] }]]
    end

    # Variable and method names that hold a model, by name: `branch`,
    # `@branch`, `home_branch` (from `class_name: "Branch"`), and plurals.
    def model_names
      names = {}
      @models.each do |model|
        one = snake(model)
        names[one] = [model, :one]
        names[plural(one)] = [model, :many]
      end
      @sources.each do |src|
        each_node(src.tree) do |node, _|
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[belongs_to has_one has_many].include?(node.name)

          args = arguments(node)
          assoc = literal_name(args.first) or next
          class_name = literal_name(keywords(args)["class_name"])
          model = class_name || @inflections.camelize(node.name == :has_many ? @inflections.singularize(assoc) : assoc)
          names[assoc] ||= [model, node.name == :has_many ? :many : :one]
        end
      end
      names
    end

    # The model an expression holds, and whether one or many, judged by its
    # last name only.
    def model_of(node)
      name = case node
      when Prism::InstanceVariableReadNode then node.name.to_s.delete_prefix("@")
      when Prism::LocalVariableReadNode then node.name.to_s
      when Prism::CallNode then node.arguments || node.block ? nil : node.name.to_s
      end
      return unless name
      return @names[name] if @names[name]

      suffix = @suffixes.find { |known| name.end_with?("_#{known}") }
      suffix && @names[suffix]
    end

    def plural(word) = @inflections.pluralize(word)

    # The model a table holds, or the table when no model in app/models does.
    def model_of_table(table)
      @tables ||= @models.to_h { |model| [plural(snake(model)), model] }
      @tables.fetch(table, table)
    end

    # `Admin::OrderItem` is an `order_item`, the name its variables take.
    def snake(constant) = @inflections.underscore(constant.split("::").last)

    def underscore_path(constant)
      constant.split("::").map { |part| @inflections.underscore(part) }.join("/")
    end

    # Every class, module, and constant a file defines, by full name, and
    # each class's superclass and `include`s as nodes, with the scopes they
    # are written in.
    def constant_table
      @defined = {}
      @parents = Hash.new { |hash, key| hash[key] = [] }
      @sources.each do |src|
        each_node(src.tree) do |node, stack|
          next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ConstantWriteNode) ||
            (node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[include prepend].include?(node.name))

          crefs = nesting(stack)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            @defined[nesting(stack + [node]).last] = true
            @parents[nesting(stack + [node]).last] << [node.superclass, crefs] if node.is_a?(Prism::ClassNode) && node.superclass
          when Prism::ConstantWriteNode
            @defined[[crefs.last, node.name.to_s].compact.join("::")] = true
          when Prism::CallNode
            next unless %i[include prepend].include?(node.name) && node.receiver.nil? && crefs.any? && stack.none?(Prism::DefNode)

            arguments(node).each do |arg|
              @parents[crefs.last] << [arg, crefs] if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
            end
          end
        end
      end
    end

    # The full name a constant reference means, the way Ruby looks it up:
    # the enclosing scopes from inside out, then the innermost scope's
    # ancestors, then the top level. `also` counts as defined (a value the
    # change removed). nil when nothing visible defines it. `seen` stops a
    # class whose `include` names itself through its ancestors from looping.
    def resolve(node, crefs, also = nil, seen = {})
      known = ->(full) { @defined[full] || full == also }
      case node
      when Prism::ConstantReadNode
        name = node.name.to_s
        hit = crefs.reverse.map { |cref| "#{cref}::#{name}" }.find(&known)
        hit ||= ancestors(crefs.last, seen).map { |owner| "#{owner}::#{name}" }.find(&known) if crefs.any?
        hit || (name if known.(name))
      when Prism::ConstantPathNode
        return path_name(node) if node.parent.nil?

        owner = resolve(node.parent, crefs, also, seen) or return
        [owner, *ancestors(owner, seen)].map { |scope| "#{scope}::#{path_name(node)}" }.find(&known)
      end
    end

    def ancestors(full, seen = {})
      return [] if seen[full]

      seen[full] = true
      @parents[full].flat_map do |ref, crefs|
        parent = resolve(ref, crefs, nil, seen) or next []
        [parent, *ancestors(parent, seen)]
      end
    end

    # Every call at head with the nodes around it. Each rule walks them for
    # each value, so they are collected once.
    def each_call(&block)
      @calls ||= @sources.flat_map do |src|
        found = []
        each_node(src.tree) { |node, stack| found << [src, node, stack.dup] if node.is_a?(Prism::CallNode) }
        found
      end
      @calls.each { |src, node, stack| block.call(src, node, stack) }
    end

    def each_node(node, stack = [], &block)
      return unless node

      yield node, stack
      stack.push(node)
      node.compact_child_nodes.each { |child| each_node(child, stack, &block) }
      stack.pop
    end

    def arguments(node)
      node.arguments&.arguments || []
    end

    def literal_name(node)
      node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end

    def keywords(args)
      hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
      return {} unless hash

      hash.elements.each_with_object({}) do |assoc, acc|
        next unless assoc.is_a?(Prism::AssocNode)

        key = literal_name(assoc.key)
        acc[key] = assoc.value if key
      end
    end

    # Prism 0.19, which Ruby 3.3 ships, names a path's last part through `child`.
    def path_name(node)
      (node.respond_to?(:name) ? node.name : node.child.name).to_s
    end

    def enclosing_class(stack)
      stack.select { |node| node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) }.map { |klass| klass.constant_path.slice }.last
    end

    # The lexical scopes around a node, outermost first, as full names:
    # `module Admin; class OrdersController` gives Admin, Admin::OrdersController.
    def nesting(stack)
      stack.select { |node| node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) }.each_with_object([]) do |klass, crefs|
        path = klass.constant_path.slice
        crefs << (path.start_with?("::") ? path.delete_prefix("::") : [crefs.last, path].compact.join("::"))
      end
    end

    def enclosing_def(stack)
      stack.grep(Prism::DefNode).last&.name
    end
  end
end
