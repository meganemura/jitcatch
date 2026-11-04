# frozen_string_literal: true

require "prism"

module JitCatch
  # Reads FactoryBot definitions as source, without loading them, so a test
  # that calls `create(:loan)` can be traced to the class the factory
  # builds. It does not know the app's inflections or any class a run
  # computes: a factory whose class the source does not settle comes back
  # with a reason and no class.
  module Factories
    Factory = Data.define(:name, :class_name, :file, :line, :reason)
    # One `factory` call as written. `outer` is the factory it nests in.
    Written = Data.define(:names, :file, :line, :own_class, :parent, :outer, :reason)

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
        names = item.names.empty? ? [nil] : item.names
        names.map { |name| Factory.new(name: name, class_name: class_name, file: item.file, line: item.line, reason: reason) }
      end
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
      own_class = nil
      if options.key?("class")
        own_class = class_named(options["class"])
        reason ||= "class: is not a constant, a string, or a symbol" unless own_class
      end
      parent = options.key?("parent") ? literal(options["parent"]) : nil
      reason ||= "parent: is not a symbol or a string" if options.key?("parent") && parent.nil?
      aliases = options["aliases"].is_a?(Prism::ArrayNode) ? options["aliases"].elements.filter_map { |element| literal(element) } : []
      Written.new(names: [name, *aliases].compact, file: file, line: node.location.start_line, own_class: own_class, parent: parent, outer: outer, reason: reason)
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
