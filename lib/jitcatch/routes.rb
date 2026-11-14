# frozen_string_literal: true
# rbs_inline: enabled

require "prism"

module JitCatch
  # Reads the routes `config/routes.rb` draws as source, without booting the
  # app, so a request a test sends to a path or a path helper names the
  # controller action that serves it. It reads `resources`, `resource`,
  # `namespace`, `scope`, `member`, `collection`, `root`, and a verb with
  # `to:`, `=>`, or `controller:` and `action:`, and names helpers and
  # controllers with the app's inflections. A route that a `draw` file, a
  # loop, or a concern draws is not read, so its helper stays unknown.
  class Routes
    Route = Data.define(
      :verb, #: String
      :path, #: String
      :helper, #: String?
      :action #: String
    )
    # `resource` is the resource whose block the statements are in: the
    # path and helper of one member, and its controller. `controller` is
    # the one `scope controller:` names.
    Scope = Data.define(
      :path, #: String
      :helper, #: String
      :modules, #: Array[String]
      :resource, #: Resource?
      :controller #: String?
    )
    Resource = Data.define(
      :member_path, #: String
      :collection_path, #: String
      :member_helper, #: String
      :collection_helper, #: String
      :controller #: String
    )

    # @rbs!
    #   # An action `resources` or `resource` draws: its name, its verb, its
    #   # path after the collection's, and the kind of helper that names it.
    #   type drawn_action = [Symbol, String, String, Symbol]

    VERBS = %i[get post put patch delete].freeze #: Array[Symbol]
    # The actions `resources` draws, in the order Rails matches them: the
    # verb, the path after the collection's, and whether the helper names
    # the collection, a member, or the member with a prefix.
    PLURAL_ACTIONS = [
      [:index, "GET", "", :collection], [:create, "POST", "", :collection], [:new, "GET", "/new", :new_member],
      [:edit, "GET", "/:id/edit", :edit_member], [:show, "GET", "/:id", :member], [:update, "PATCH", "/:id", :member],
      [:update, "PUT", "/:id", :member], [:destroy, "DELETE", "/:id", :member]
    ].freeze #: Array[drawn_action]
    SINGULAR_ACTIONS = [
      [:new, "GET", "/new", :new_member], [:edit, "GET", "/edit", :edit_member], [:show, "GET", "", :member],
      [:create, "POST", "", :member], [:update, "PATCH", "", :member], [:update, "PUT", "", :member], [:destroy, "DELETE", "", :member]
    ].freeze #: Array[drawn_action]
    # Blocks whose routes keep the scope around them.
    PASS_THROUGH = %i[constraints defaults].freeze #: Array[Symbol]

    # @rbs @inflections: Inflections
    # @rbs @routes: Array[Route]

    #: (String? source, ?Inflections inflections) -> Routes
    def self.parse(source, inflections = Inflections.rails)
      routes = new(inflections)
      result = source ? Prism.parse(source) : nil
      routes.read(result.value, Scope.new(path: "", helper: "", modules: [], resource: nil, controller: nil)) if result&.success?
      routes
    end

    #: (Inflections inflections) -> void
    def initialize(inflections)
      @inflections = inflections
      @routes = []
    end

    #: (String action) -> bool
    def drawn?(action)
      @routes.any? { |route| route.action == action }
    end

    #: (String name) -> bool
    def helper?(name)
      !route_for_helper(name).nil?
    end

    # The first route a `*_path` or `*_url` helper builds a URL for, or nil.
    #: (String name) -> Route?
    def route_for_helper(name)
      return nil unless name.end_with?("_path", "_url")

      bare = name.sub(/_(?:path|url)\z/, "")
      @routes.find { |route| route.helper == bare }
    end

    # The controller actions a request (`POST things_path`, or
    # `GET /things/7`, `*` for a segment the test computes) reaches: by
    # helper, each action that helper serves for the verb; by path, the
    # first route Rails would match, a computed segment preferring a
    # `:param` to a literal one.
    #: (String request) -> Array[String]
    def actions(request)
      verb, target = request.split(" ", 2) #: [String, String]
      if SourceIndex.route_helper_request?(request)
        bare = target.delete_suffix("_path")
        return @routes.select { |route| route.verb == verb && route.helper == bare }.map(&:action).uniq
      end

      drawn = @routes.select { |route| route.verb == verb }
      found = drawn.find { |route| reaches?(target, route.path, false) } || drawn.find { |route| reaches?(target, route.path, true) }
      found ? [found.action] : []
    end

    # A path the app serves itself, so the request names every segment of
    # the route, unless it starts with a part the test computes.
    #: (String sent_path, String route_path, bool computed_matches_literal) -> bool
    def reaches?(sent_path, route_path, computed_matches_literal)
      sent = sent_path.split("/").reject(&:empty?)
      open_mount = sent.first == SourceIndex::COMPUTED_SEGMENT
      sent = sent.drop(1) if open_mount
      wanted = route_path.split("/").reject(&:empty?)
      return false if open_mount ? sent.size > wanted.size : sent.size != wanted.size

      sent.zip(wanted.last(sent.size)).all? do |part, want|
        want.to_s.start_with?(":") || part == want || (part == SourceIndex::COMPUTED_SEGMENT && computed_matches_literal)
      end
    end

    #: (Prism::Node? node, Scope scope) -> void
    def read(node, scope)
      statements(node).each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?

        args = Array(stmt.arguments&.arguments)
        options = keyword_options(args)
        # A block passed with `&` draws its routes at run time, so it is not read.
        block = stmt.block.is_a?(Prism::BlockNode) ? stmt.block : nil
        case stmt.name
        when :resources, :resource
          plural = stmt.name == :resources
          symbol_names(args).each { |name| read_resource(name, plural, options, block, scope) }
        when :namespace
          name = symbol_names(args).first
          next unless name && block

          read(block.body, scope.with(path: "#{scope.path}/#{name}", helper: "#{scope.helper}#{name}_", modules: [*scope.modules, name], resource: nil, controller: nil))
        when :scope
          path = string_of(args.first) || string_of(options["path"])
          as = string_of(options["as"])
          read(block&.body, scope.with(path: path ? "#{scope.path}/#{path.delete_prefix("/")}" : scope.path, modules: modules_of(scope, options),
            helper: as ? "#{scope.helper}#{as}_" : scope.helper, controller: string_of(options["controller"]) || scope.controller))
        when :member, :collection
          resource = scope.resource
          next unless resource && block

          member = stmt.name == :member
          read_actions(block.body, scope, member ? resource.member_path : resource.collection_path, member ? resource.member_helper : resource.collection_helper, resource.controller)
        when :root
          target = string_of(args.first) || target_of(options, scope, nil)
          add("GET", scope.path.empty? ? "/" : scope.path, "#{scope.helper}root", target, scope)
        when *VERBS
          read_verb(stmt.name, args, options, scope)
        when *PASS_THROUGH
          read(block&.body, scope)
        end
      end
    end

    private

    # Rails names the helpers after `as:` when it is given, and adds
    # `_index` to the collection's when the name has one form for both.
    #: (String name, bool plural, Hash[String, Prism::Node] options, Prism::BlockNode? block, Scope scope) -> void
    def read_resource(name, plural, options, block, scope)
      only = symbol_list(options["only"])
      except = symbol_list(options["except"]) || []
      segment = string_of(options["path"]) || name
      named = string_of(options["as"]) || name
      singular = plural ? @inflections.singularize(named) : named
      controller = string_of(options["controller"]) || (plural ? name : @inflections.pluralize(name))
      scope = scope.with(modules: modules_of(scope, options))
      collection_path = "#{scope.path}/#{segment}"
      member_path = plural ? "#{collection_path}/:id" : collection_path
      collection_helper = "#{scope.helper}#{plural && singular == named ? "#{named}_index" : named}"
      member_helper = "#{scope.helper}#{singular}"
      action_of = ->(action) { action(scope.modules, controller, action) }
      (plural ? PLURAL_ACTIONS : SINGULAR_ACTIONS).each do |action, verb, suffix, helper_kind|
        next if (only && !only.include?(action.to_s)) || except.include?(action.to_s)

        helper = case helper_kind
        when :collection then collection_helper
        when :member then member_helper
        else "#{helper_kind.to_s.delete_suffix("_member")}_#{member_helper}"
        end
        @routes << Route.new(verb: verb, path: "#{collection_path}#{suffix}", helper: helper, action: action_of.(action))
      end
      return unless block

      nested_path = plural ? "#{collection_path}/:#{singular}_id" : collection_path
      resource = Resource.new(member_path: member_path, collection_path: collection_path, member_helper: member_helper, collection_helper: collection_helper,
        controller: controller)
      read(block.body, scope.with(path: nested_path, helper: "#{member_helper}_", resource: resource))
    end

    # `post :shelve` in a `member` or `collection` block, or with `on:`.
    #: (Prism::Node? body, Scope scope, String path, String helper, String controller) -> void
    def read_actions(body, scope, path, helper, controller)
      statements(body).each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && VERBS.include?(stmt.name)

        symbol_names(Array(stmt.arguments&.arguments)).each do |action|
          add_action(stmt.name, "#{path}/#{action}", "#{action}_#{helper}", controller, action, scope)
        end
      end
    end

    #: (Symbol verb, String path, String helper, String controller, String action, Scope scope) -> Array[Route]
    def add_action(verb, path, helper, controller, action, scope)
      @routes << Route.new(verb: verb.to_s.upcase, path: path, helper: helper, action: action(scope.modules, controller, action))
    end

    #: (Symbol verb, Array[Prism::Node] args, Hash[String, Prism::Node] options, Scope scope) -> void
    def read_verb(verb, args, options, scope)
      resource = scope.resource
      on = string_of(options["on"])
      if resource && %w[member collection].include?(on)
        member = on == "member"
        path = member ? resource.member_path : resource.collection_path
        helper = member ? resource.member_helper : resource.collection_helper
        symbol_names(args).each { |action| add_action(verb, "#{path}/#{action}", "#{action}_#{helper}", resource.controller, action, scope) }
        return
      end

      # In a `resources` block with no `on:`, Rails nests the action under
      # the member's id, as `/things/:thing_id/refresh`.
      first = args.first
      if resource && first.is_a?(Prism::SymbolNode) && !options.key?("to")
        action = first.unescaped
        return add_action(verb, "#{scope.path}/#{action}", "#{scope.helper}#{action}", resource.controller, action, scope)
      end

      path, target = path_and_target(args, options, scope)
      return unless path && target

      helper = string_of(options["as"]) || (path.match?(%r{\A[\w/]+\z}) ? path.delete_prefix("/").tr("/", "_") : nil)
      add(verb.to_s.upcase, "#{scope.path}/#{path.delete_prefix("/")}", helper && "#{scope.helper}#{helper}", target, scope)
    end

    # `get "about", to: "pages#about"`, `get "about" => "pages#about"`, and
    # `get "about", controller: :pages, action: :about`, whose controller
    # can come from `scope controller:` and whose action defaults to the
    # path.
    #: (Array[Prism::Node] args, Hash[String, Prism::Node] options, Scope scope) -> [String?, String?]
    def path_and_target(args, options, scope)
      first = args.first
      if first.is_a?(Prism::KeywordHashNode)
        # Array#grep does not narrow its elements to the class it is given.
        pairs = first.elements.grep(Prism::AssocNode) #: Array[untyped]
        pair = pairs.find { |assoc| assoc.key.is_a?(Prism::StringNode) }
        return [pair.key.unescaped, string_of(pair.value)] if pair
      end
      path = string_of(first)
      [path, target_of(options, scope, path)]
    end

    # The `controller#action` a route serves, or nil.
    #: (Hash[String, Prism::Node] options, Scope scope, String? path) -> String?
    def target_of(options, scope, path)
      to = string_of(options["to"])
      return to if to

      controller = string_of(options["controller"]) || scope.controller
      action = string_of(options["action"]) || (path if path&.match?(/\A\w+\z/))
      "#{controller}##{action}" if controller && action
    end

    #: (Scope scope, Hash[String, Prism::Node] options) -> Array[String]
    def modules_of(scope, options)
      (module_name = string_of(options["module"])) ? [*scope.modules, module_name] : scope.modules
    end

    #: (String verb, String path, String? helper, String? target, Scope scope) -> void
    def add(verb, path, helper, target, scope)
      controller, action = target.to_s.split("#", 2)
      return unless controller && action

      @routes << Route.new(verb: verb, path: path, helper: helper, action: action(scope.modules, controller, action))
    end

    # Rails camelizes `admin/api_keys` with the app's acronyms.
    #: (Array[String] modules, String controller, String action) -> String
    def action(modules, controller, action)
      names = [*modules, *controller.split("/")]
      outer = names[0...-1] #: Array[String]
      "#{outer.map { |name| @inflections.camelize(name) }.push("#{@inflections.camelize(names.last)}Controller").join("::")}##{action}"
    end

    #: (Prism::Node? node) -> Array[Prism::Node]
    def statements(node)
      case node
      when nil then []
      when Prism::ProgramNode then statements(node.statements)
      when Prism::StatementsNode then node.body.flat_map { |stmt| draw_body(stmt) }
      when Prism::BeginNode then statements(node.statements)
      else [node]
      end
    end

    # The statements of `Rails.application.routes.draw do ... end`.
    #: (Prism::Node stmt) -> Array[Prism::Node]
    def draw_body(stmt)
      return [stmt] unless stmt.is_a?(Prism::CallNode) && stmt.name == :draw && stmt.block.is_a?(Prism::BlockNode)

      statements(stmt.block.body)
    end

    # The options a call passes by symbol, by name.
    #: (Array[Prism::Node] args) -> Hash[String, Prism::Node]
    def keyword_options(args)
      hash = args.grep(Prism::KeywordHashNode).first #: Prism::KeywordHashNode?
      return {} unless hash

      pairs = hash.elements.grep(Prism::AssocNode) #: Array[untyped]
      pairs.select { |pair| pair.key.is_a?(Prism::SymbolNode) }.to_h { |pair| [pair.key.unescaped, pair.value] }
    end

    #: (Array[Prism::Node] args) -> Array[String]
    def symbol_names(args)
      args.filter_map { |arg| arg.unescaped if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }
    end

    #: (Prism::Node? node) -> Array[String]?
    def symbol_list(node)
      case node
      when nil then nil
      when Prism::ArrayNode then node.elements.filter_map { |element| string_of(element) }
      else [string_of(node)].compact
      end
    end

    #: (Prism::Node? node) -> String?
    def string_of(node)
      node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end
  end
end
