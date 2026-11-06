# frozen_string_literal: true

require "prism"

module JitCatch
  # Reads the routes `config/routes.rb` draws as source, without booting the
  # app, so a request a test sends to a path or a path helper names the
  # controller action that serves it. It reads `resources`, `resource`,
  # `namespace`, `scope`, `member`, `collection`, `root`, and a verb with
  # `to:` or `=>`. A route that a `draw` file, a loop, a concern, or the
  # app's inflections decide is not read, so its helper stays unknown.
  class Routes
    Route = Data.define(:verb, :path, :helper, :action)
    # `resource` is the resource whose block the statements are in: the
    # path and helper of one member, and its controller.
    Scope = Data.define(:path, :helper, :modules, :resource)
    Resource = Data.define(:member_path, :collection_path, :member_helper, :collection_helper, :controller)

    VERBS = %i[get post put patch delete].freeze
    # The actions `resources` draws, in the order Rails matches them: the
    # verb, the path after the collection's, and whether the helper names
    # the collection, a member, or the member with a prefix.
    PLURAL_ACTIONS = [
      [:index, "GET", "", :collection], [:create, "POST", "", :collection], [:new, "GET", "/new", :new_member],
      [:edit, "GET", "/:id/edit", :edit_member], [:show, "GET", "/:id", :member], [:update, "PATCH", "/:id", :member],
      [:update, "PUT", "/:id", :member], [:destroy, "DELETE", "/:id", :member]
    ].freeze
    SINGULAR_ACTIONS = [
      [:new, "GET", "/new", :new_member], [:edit, "GET", "/edit", :edit_member], [:show, "GET", "", :member],
      [:create, "POST", "", :member], [:update, "PATCH", "", :member], [:update, "PUT", "", :member], [:destroy, "DELETE", "", :member]
    ].freeze
    # Blocks whose routes keep the scope around them.
    PASS_THROUGH = %i[constraints defaults].freeze

    def self.parse(source)
      routes = new
      result = source ? Prism.parse(source) : nil
      routes.read(result.value, Scope.new(path: "", helper: "", modules: [], resource: nil)) if result&.success?
      routes
    end

    def initialize
      @routes = []
    end

    def helper?(name)
      bare = name.delete_suffix("_path")
      @routes.any? { |route| route.helper == bare }
    end

    # The controller actions a request (`POST things_path`, or
    # `GET /things/7`, `*` for a segment the test computes) reaches: by
    # helper, each action that helper serves for the verb; by path, the
    # first route Rails would match, a computed segment preferring a
    # `:param` to a literal one.
    def actions(request)
      verb, target = request.split(" ", 2)
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
    def reaches?(sent_path, route_path, computed_matches_literal)
      sent = sent_path.split("/").reject(&:empty?)
      open_mount = sent.first == SourceIndex::COMPUTED_SEGMENT
      sent = sent.drop(1) if open_mount
      wanted = route_path.split("/").reject(&:empty?)
      return false if open_mount ? sent.size > wanted.size : sent.size != wanted.size

      sent.zip(wanted.last(sent.size)).all? do |part, want|
        want.start_with?(":") || part == want || (part == SourceIndex::COMPUTED_SEGMENT && computed_matches_literal)
      end
    end

    def read(node, scope)
      statements(node).each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?

        args = Array(stmt.arguments&.arguments)
        options = keyword_options(args)
        case stmt.name
        when :resources, :resource
          plural = stmt.name == :resources
          symbol_names(args).each { |name| read_resource(name, plural, options, stmt.block, scope) }
        when :namespace
          name = symbol_names(args).first
          next unless name && stmt.block

          read(stmt.block.body, scope.with(path: "#{scope.path}/#{name}", helper: "#{scope.helper}#{name}_", modules: [*scope.modules, name], resource: nil))
        when :scope
          path = string_of(args.first) || string_of(options["path"])
          modules = (module_name = string_of(options["module"])) ? [*scope.modules, module_name] : scope.modules
          read(stmt.block&.body, scope.with(path: path ? "#{scope.path}/#{path.delete_prefix("/")}" : scope.path, modules: modules))
        when :member, :collection
          resource = scope.resource
          next unless resource && stmt.block

          member = stmt.name == :member
          read_actions(stmt.block.body, scope, member ? resource.member_path : resource.collection_path, member ? resource.member_helper : resource.collection_helper, resource.controller)
        when :root
          target = string_of(args.first) || string_of(options["to"])
          add("GET", scope.path.empty? ? "/" : scope.path, "#{scope.helper}root", target, scope)
        when *VERBS
          read_verb(stmt.name, args, options, scope)
        when *PASS_THROUGH
          read(stmt.block&.body, scope)
        end
      end
    end

    private

    def read_resource(name, plural, options, block, scope)
      only = symbol_list(options["only"])
      except = symbol_list(options["except"]) || []
      segment = string_of(options["path"]) || name
      singular = plural ? Routes.singular(name) : name
      controller = string_of(options["controller"]) || (plural ? name : "#{name}s")
      collection_path = "#{scope.path}/#{segment}"
      member_path = plural ? "#{collection_path}/:id" : collection_path
      collection_helper = "#{scope.helper}#{name}"
      member_helper = "#{scope.helper}#{singular}"
      action_of = ->(action) { Routes.action(scope.modules, controller, action) }
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
    def read_actions(body, scope, path, helper, controller)
      statements(body).each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && VERBS.include?(stmt.name)

        symbol_names(Array(stmt.arguments&.arguments)).each do |action|
          add_action(stmt.name, "#{path}/#{action}", "#{action}_#{helper}", controller, action, scope)
        end
      end
    end

    def add_action(verb, path, helper, controller, action, scope)
      @routes << Route.new(verb: verb.to_s.upcase, path: path, helper: helper, action: Routes.action(scope.modules, controller, action))
    end

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
      if resource && args.first.is_a?(Prism::SymbolNode) && !options.key?("to")
        action = args.first.unescaped
        return add_action(verb, "#{scope.path}/#{action}", "#{scope.helper}#{action}", resource.controller, action, scope)
      end

      path, target = path_and_target(args, options)
      return unless path && target

      helper = string_of(options["as"]) || (path.match?(%r{\A[\w/]+\z}) ? path.delete_prefix("/").tr("/", "_") : nil)
      add(verb.to_s.upcase, "#{scope.path}/#{path.delete_prefix("/")}", helper && "#{scope.helper}#{helper}", target, scope)
    end

    # `get "about", to: "pages#about"` and `get "about" => "pages#about"`.
    def path_and_target(args, options)
      first = args.first
      if first.is_a?(Prism::KeywordHashNode)
        pair = first.elements.grep(Prism::AssocNode).find { |assoc| assoc.key.is_a?(Prism::StringNode) }
        return [pair.key.unescaped, string_of(pair.value)] if pair
      end
      [string_of(first), string_of(options["to"])]
    end

    def add(verb, path, helper, target, scope)
      controller, action = target.to_s.split("#", 2)
      return unless controller && action

      @routes << Route.new(verb: verb, path: path, helper: helper, action: Routes.action(scope.modules, controller, action))
    end

    def self.action(modules, controller, action)
      names = [*modules, *controller.split("/")]
      "#{names[0...-1].map { |name| camel(name) }.push("#{camel(names.last)}Controller").join("::")}##{action}"
    end

    def self.camel(name)
      name.split("_").map(&:capitalize).join
    end

    # The English plurals a resource name takes most often; an app's own
    # inflections are not read.
    def self.singular(name)
      case name
      when /ies\z/ then name.sub(/ies\z/, "y")
      when /(ss|us|x|ch|sh)es\z/ then name.sub(/es\z/, "")
      else name.delete_suffix("s")
      end
    end

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
    def draw_body(stmt)
      return [stmt] unless stmt.is_a?(Prism::CallNode) && stmt.name == :draw && stmt.block

      statements(stmt.block.body)
    end

    def keyword_options(args)
      hash = args.grep(Prism::KeywordHashNode).first
      return {} unless hash

      hash.elements.grep(Prism::AssocNode).select { |pair| pair.key.is_a?(Prism::SymbolNode) }.to_h { |pair| [pair.key.unescaped, pair.value] }
    end

    def symbol_names(args)
      args.select { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }.map(&:unescaped)
    end

    def symbol_list(node)
      case node
      when nil then nil
      when Prism::ArrayNode then node.elements.filter_map { |element| string_of(element) }
      else [string_of(node)].compact
      end
    end

    def string_of(node)
      node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end
  end
end
