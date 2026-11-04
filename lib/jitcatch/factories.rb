# frozen_string_literal: true

require "prism"

module JitCatch
  # Reads FactoryBot definitions as source, without loading them, so a test
  # that calls `create(:loan)` can be traced to the class the factory
  # builds. It does not know the app's inflections or any class a run
  # computes: a factory whose class the source does not settle comes back
  # with a reason and no class.
  module Factories
    # `builds` holds the classes its associations build, through their own
    # associations too. `trait_builds` holds, by trait name, what a trait
    # builds when a test names it.
    Factory = Data.define(:name, :class_name, :file, :line, :reason, :builds, :trait_builds)
    # One `factory` call as written. `outer` is the factory it nests in.
    # `associations` names the factories it may build with: a bare name
    # counts only when a factory of that name exists. `traits` holds the
    # names of each trait's associations.
    Written = Data.define(:names, :file, :line, :own_class, :parent, :outer, :reason, :associations, :traits)

    # Calls in a factory block that define something other than an attribute.
    DEFINITIONS = %i[factory trait transient sequence after before callback traits_for_enum initialize_with to_create skip_create].freeze

    module_function

    def file?(path)
      path.match?(%r{(?:\A|/)(?:spec|test)/factories(?:\.rb\z|/.*\.rb\z)})
    end

    # A parent can be defined in another file, so every file is read before
    # any class is settled.
    def read(sources)
      written = sources.sort.flat_map { |file, source| collect(Prism.parse(source).value, file, nil) }
      by_name = written.flat_map { |item| item.names.map { |name| [name, item] } }.to_h
      written.flat_map do |item|
        class_name, reason = settle(item, by_name, [])
        builds = classes_built(built_with(item, by_name, [item]), by_name)
        trait_builds = traits_of(item, by_name, [item]).transform_values { |names|
          classes_built(names.filter_map { |name| by_name[name] }.flat_map { |other| [other, *built_with(other, by_name, [other])] }, by_name)
        }
        names = item.names.empty? ? [nil] : item.names
        names.map { |name| Factory.new(name: name, class_name: class_name, file: item.file, line: item.line, reason: reason, builds: builds, trait_builds: trait_builds) }
      end
    end

    def classes_built(items, by_name)
      items.filter_map { |other| settle(other, by_name, [])[0] }.uniq.sort
    end

    # A factory can use the traits of its parent and of the factory it
    # nests in, and its own trait of the same name wins.
    def traits_of(item, by_name, seen)
      inherited = [item.outer, item.parent && by_name[item.parent]].compact.reject { |other| seen.include?(other) }
      inherited.reverse.map { |other| traits_of(other, by_name, [*seen, other]) }.reduce({}, :merge).merge(item.traits).sort.to_h
    end

    def collect(node, file, outer)
      if node.is_a?(Prism::CallNode) && node.name == :factory && node.receiver.nil?
        item = written(node, file, outer)
        return [item, *collect(node.block, file, item)]
      end
      return [] if node.nil?

      node.compact_child_nodes.flat_map { |child| collect(child, file, outer) }
    end

    def written(node, file, outer)
      first, *rest = Array(node.arguments&.arguments)
      options = rest.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .select { |pair| pair.key.is_a?(Prism::SymbolNode) }.to_h { |pair| [pair.key.unescaped, pair.value] }
      name = literal(first)
      reason = "its name is not a symbol or a string" unless name
      own_class = class_named(options["class"]) if options.key?("class")
      reason ||= "class: is not a constant, a string, or a symbol" if options.key?("class") && own_class.nil?
      parent = options.key?("parent") ? literal(options["parent"]) : nil
      reason ||= "parent: is not a symbol or a string" if options.key?("parent") && parent.nil?
      aliases = options["aliases"].is_a?(Prism::ArrayNode) ? options["aliases"].elements.filter_map { |element| literal(element) } : []
      Written.new(names: [name, *aliases].compact, file: file, line: node.location.start_line, own_class: own_class, parent: parent, outer: outer, reason: reason,
        associations: associations_in(node.block), traits: traits_in(node.block))
    end

    def traits_in(block)
      statements = block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode) ? block.body.body : []
      statements.grep(Prism::CallNode).select { |call| call.receiver.nil? && call.name == :trait }.filter_map { |call|
        name = literal(call.arguments&.arguments&.first)
        [name, associations_in(call.block)] if name
      }.to_h
    end

    # The statements of the factory's own block. A trait runs only when a
    # test names it, and a nested factory is a factory of its own.
    def associations_in(block)
      statements = block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode) ? block.body.body : []
      statements.grep(Prism::CallNode).flat_map do |call|
        next [] unless call.receiver.nil? && !DEFINITIONS.include?(call.name)
        next [association_name(call)].compact if call.name == :association
        next [call.name.to_s] if call.arguments.nil? && call.block.nil?
        next [] unless call.block.is_a?(Prism::BlockNode) && call.block.body.is_a?(Prism::StatementsNode)

        call.block.body.body.grep(Prism::CallNode).select { |inner| inner.receiver.nil? && inner.name == :association }.filter_map { |inner| association_name(inner) }
      end
    end

    # `association :author, factory: :user` builds from :user, and
    # `factory: [:user, :admin]` from :user with a trait.
    def association_name(call)
      first, *rest = Array(call.arguments&.arguments)
      factory = rest.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .find { |pair| pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == "factory" }&.value
      factory = factory.elements.first if factory.is_a?(Prism::ArrayNode)
      literal(factory) || literal(first)
    end

    # The factories an item builds with, its parent's and the one it nests
    # in included, since a child factory inherits their attributes.
    def built_with(item, by_name, seen)
      inherited = [item.parent && by_name[item.parent], item.outer].compact
      direct = item.associations.filter_map { |name| by_name[name] }
      (direct + inherited).reject { |other| seen.include?(other) }.uniq.flat_map do |other|
        reached = built_with(other, by_name, [*seen, other])
        inherited.include?(other) ? reached : [other, *reached]
      end
    end

    # FactoryBot takes a factory's class from its own `class:`, then from
    # its parent (named by `parent:`, or the factory it nests in), then
    # from its name.
    def settle(item, by_name, seen)
      return [nil, item.reason] if item.reason
      return [item.own_class, nil] if item.own_class

      if item.parent
        parent = by_name[item.parent]
        return [nil, "its parent :#{item.parent} is not a factory read here"] if parent.nil? || seen.include?(parent)

        return settle(parent, by_name, [*seen, item])
      end
      return settle(item.outer, by_name, [*seen, item]) if item.outer

      [camelize(item.names.first), nil]
    end

    # A string or a symbol that starts in upper case is a constant's name,
    # and FactoryBot camelizes any other.
    def class_named(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        node.location.slice.delete(" ").delete_prefix("::")
      when Prism::StringNode, Prism::SymbolNode
        text = node.unescaped.delete_prefix("::")
        text.match?(/\A[A-Z]/) ? text : camelize(text)
      end
    end

    def literal(node)
      node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end

    def camelize(name)
      name.split("/").map { |part| part.split("_").map { |word| word.sub(/\A./) { |letter| letter.upcase } }.join }.join("::")
    end
  end
end
