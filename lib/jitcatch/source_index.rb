# frozen_string_literal: true

require "prism"

module JitCatch
  # Indexes methods, constants, and calls in one Ruby file.
  # Dynamic definitions (`define_method`, `class_eval`) are not indexed.
  class SourceIndex
    VISIBILITY = %i[public private protected].freeze
    CLASS_VISIBILITY = { private_class_method: :private, public_class_method: :public }.freeze

    Method = Data.define(
      :file, :bare_name, :qualifier, :qualified, :kind, :visibility,
      :start_line, :end_line, :source, :params
    )
    Constant = Data.define(
      :file, :bare_name, :qualifier, :qualified, :start_line, :end_line, :source
    )
    Call = Data.define(:file, :bare_name, :line, :enclosing)

    attr_reader :methods, :constants, :namespaces, :calls, :private_constants, :parse_error

    def self.parse(source, file:)
      new(source, file).parse
    end

    def initialize(source, file)
      @source = source.to_s.gsub("\r\n", "\n")
      @lines = @source.lines
      @file = file.tr("\\", "/")
      @methods = []
      @constants = []
      @namespaces = []
      @module_functions = []
      @private_constants = []
      @calls = []
      @parse_error = nil
    end

    def parse
      result = Prism.parse(@source)
      unless result.success?
        @parse_error = result.errors.map { |err| "L#{err.location.start_line}: #{err.message}" }.sort.join("; ")
        return self
      end

      scan_body(result.value, "", :public, false)
      walk(result.value, "", false, nil)
      rename_module_function_callers
      @methods = self.class.hide_private_constants(@methods, @private_constants)
      self
    end

    def self.qualify(qualifier, bare, singleton)
      sep = singleton ? "." : "#"
      qualifier.to_s.empty? ? "#{sep}#{bare}" : "#{qualifier}#{sep}#{bare}"
    end

    def self.split_qualified(qname)
      if (idx = qname.rindex("#"))
        [qname[0...idx], "#", qname[(idx + 1)..]]
      elsif (idx = qname.rindex("."))
        [qname[0...idx], ".", qname[(idx + 1)..]]
      else
        ["", "#", qname]
      end
    end

    # Code outside the namespace cannot name a private constant, so no method
    # under it is an entry point, whatever its own visibility says. A revision
    # passes the names from all its files, since a namespace can be reopened.
    def self.hide_private_constants(methods, names)
      return methods if names.empty?

      methods.map do |method|
        hidden = names.any? { |name| method.qualifier == name || method.qualifier.start_with?("#{name}::") }
        hidden ? method.with(visibility: "private") : method
      end
    end

    private

    def scan_body(node, qualifier, visibility, singleton)
      vis = visibility
      statements(node).each do |stmt|
        vis = scan_statement(stmt, qualifier, vis, singleton)
      end
    end

    def statements(node)
      container = if node.is_a?(Prism::ProgramNode)
        node.statements
      elsif node.respond_to?(:body)
        node.body
      else
        node
      end
      case container
      when nil then []
      when Prism::StatementsNode then container.body
      else [container]
      end
    end

    def scan_statement(stmt, qualifier, visibility, singleton)
      case stmt
      when Prism::ClassNode, Prism::ModuleNode
        name = const_name(stmt.constant_path)
        nested = join_qual(qualifier, name)
        record_constant(@namespaces, nested, stmt.location.start_line, stmt.location.end_line, @lines[stmt.location.start_line - 1]) if name
        scan_body(stmt, nested, :public, false)
        visibility
      when Prism::SingletonClassNode
        scan_body(stmt, qualifier, :public, true)
        visibility
      when Prism::DefNode
        record_method(stmt, qualifier, visibility, singleton)
        visibility
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        full = constant_target(stmt, qualifier)
        source, end_line = constant_header(stmt)
        record_constant(@constants, full, stmt.location.start_line, end_line, source)
        block = value_block(stmt)
        scan_body(block, full, :public, false) if block
        visibility
      when Prism::CallNode
        return handle_visibility(stmt, qualifier, visibility, singleton) if visibility_modifier?(stmt)

        return handle_module_function(stmt, qualifier, visibility) if stmt.receiver.nil? && stmt.name == :module_function

        record_private_constants(stmt, qualifier) if stmt.name == :private_constant && (stmt.receiver.nil? || stmt.receiver.is_a?(Prism::SelfNode))

        handle_class_visibility(stmt, qualifier) if stmt.receiver.nil? && CLASS_VISIBILITY.key?(stmt.name)
        visibility
      else
        visibility
      end
    end

    def visibility_modifier?(node)
      node.receiver.nil? && VISIBILITY.include?(node.name)
    end

    def handle_visibility(stmt, qualifier, visibility, singleton)
      args = stmt.arguments&.arguments || []
      return stmt.name if args.empty?

      args.each do |arg|
        case arg
        when Prism::DefNode
          record_method(arg, qualifier, stmt.name, singleton)
        when Prism::SymbolNode
          mark_visibility(qualifier, arg.unescaped.to_s, stmt.name, singleton)
        end
      end
      visibility
    end

    # `module_function` makes the public method `Mod.name` that callers use;
    # the private instance copy it also makes is not listed.
    def handle_module_function(stmt, qualifier, visibility)
      args = stmt.arguments&.arguments || []
      return :module_function if args.empty?

      args.each do |arg|
        case arg
        when Prism::DefNode
          record_method(arg, qualifier, :module_function, false)
        when Prism::SymbolNode, Prism::StringNode
          to_module_function(qualifier, arg.unescaped.to_s)
        end
      end
      visibility
    end

    def to_module_function(qualifier, bare)
      @methods.map! do |method|
        next method unless method.qualifier == qualifier.to_s && method.bare_name == bare && method.kind == "instance"

        @module_functions << method.qualified
        method.with(kind: "singleton", visibility: "public", qualified: self.class.qualify(qualifier, bare, true))
      end
    end

    def record_private_constants(stmt, qualifier)
      (stmt.arguments&.arguments || []).each do |arg|
        @private_constants << join_qual(qualifier, arg.unescaped.to_s) if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      end
    end

    def handle_class_visibility(stmt, qualifier)
      visibility = CLASS_VISIBILITY.fetch(stmt.name)
      (stmt.arguments&.arguments || []).each do |arg|
        case arg
        when Prism::DefNode
          record_method(arg, qualifier, visibility, true, explicit: true)
        when Prism::SymbolNode, Prism::StringNode
          mark_visibility(qualifier, arg.unescaped.to_s, visibility, true)
        end
      end
    end

    def record_method(node, qualifier, visibility, singleton_context, explicit: false)
      # `def self.foo` stays public; bare `private` does not apply to it.
      # Visibility inside `class << self` still applies to receiver-less defs.
      explicit_receiver = !node.receiver.nil?
      module_function = visibility == :module_function && !explicit_receiver && !singleton_context
      singleton = singleton_context || explicit_receiver || module_function
      visibility = :public if (explicit_receiver && !explicit) || visibility == :module_function
      @module_functions << self.class.qualify(qualifier, node.name.to_s, false) if module_function
      bare = node.name.to_s
      params = node.parameters&.location&.slice.to_s.gsub(/\s+/, "")
      @methods << self.class::Method.new(
        file: @file,
        bare_name: bare,
        qualifier: qualifier.to_s,
        qualified: self.class.qualify(qualifier, bare, singleton),
        kind: singleton ? "singleton" : "instance",
        visibility: visibility.to_s,
        start_line: node.location.start_line,
        end_line: node.location.end_line,
        source: extract_lines(node.location.start_line, node.location.end_line),
        params: params
      )
    end

    def mark_visibility(qualifier, bare, visibility, singleton)
      kind = singleton ? "singleton" : "instance"
      @methods.map! do |method|
        if method.qualifier == qualifier.to_s && method.bare_name == bare && method.kind == kind
          method.with(visibility: visibility.to_s)
        else
          method
        end
      end
    end

    # A class or module header goes to the namespaces; it stands for the
    # body, which belongs to the methods and constants inside it.
    def record_constant(list, full, start_line, end_line, source)
      bare = full.split("::").last
      list << self.class::Constant.new(
        file: @file,
        bare_name: bare,
        qualifier: full.delete_suffix(bare).delete_suffix("::"),
        qualified: full,
        start_line: start_line,
        end_line: end_line,
        source: source.strip
      )
    end

    # The walk names an enclosing method by its `def`, which reads as an
    # instance method; a module function is listed as `Mod.name`.
    def rename_module_function_callers
      renamed = @module_functions.to_h { |name| [name, name.sub(/#(?=[^#]*\z)/, ".")] }
      @calls.map! { |call| renamed.key?(call.enclosing) ? call.with(enclosing: renamed[call.enclosing]) : call }
    end

    def constant_target(node, qualifier)
      node.is_a?(Prism::ConstantWriteNode) ? join_qual(qualifier, node.name.to_s) : const_name(node.target).to_s
    end

    # `Point = Struct.new(:x) do ... end` and `Class.new do ... end` define
    # methods for that constant. Those methods are indexed on their own, so
    # the constant keeps only the text before the block.
    def value_block(node)
      value = node.value
      value.block if value.is_a?(Prism::CallNode) && value.block.is_a?(Prism::BlockNode)
    end

    def constant_header(node)
      block = value_block(node)
      return [slice_of(node), node.location.end_line] unless block

      length = block.location.start_offset - node.location.start_offset
      [@source.byteslice(node.location.start_offset, length).force_encoding(@source.encoding).rstrip, block.location.start_line]
    end

    def walk(node, qualifier, singleton_context, enclosing)
      case node
      when Prism::ClassNode
        q = join_qual(qualifier, const_name(node.constant_path))
        node.compact_child_nodes.each { |child| walk(child, q, false, enclosing) }
      when Prism::ModuleNode
        q = join_qual(qualifier, const_name(node.constant_path))
        node.compact_child_nodes.each { |child| walk(child, q, false, enclosing) }
      when Prism::SingletonClassNode
        node.compact_child_nodes.each { |child| walk(child, qualifier, true, enclosing) }
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        owner = value_block(node) ? constant_target(node, qualifier) : qualifier
        node.compact_child_nodes.each { |child| walk(child, owner, singleton_context, enclosing) }
      when Prism::DefNode
        singleton = singleton_context || !node.receiver.nil?
        qname = self.class.qualify(qualifier, node.name.to_s, singleton)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, qname) }
      when Prism::CallNode
        if node.name
          @calls << self.class::Call.new(
            file: @file,
            bare_name: node.name.to_s,
            line: node.location.start_line,
            enclosing: enclosing
          )
        end
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      else
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      end
    end

    def const_name(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantWriteNode
        node.name.to_s
      when Prism::ConstantPathNode
        parent = node.parent ? const_name(node.parent) : nil
        [parent, node.name.to_s].compact.reject(&:empty?).join("::")
      else
        nil
      end
    end

    def join_qual(qualifier, name)
      return qualifier.to_s if name.nil? || name.empty?
      return name if qualifier.to_s.empty?

      "#{qualifier}::#{name}"
    end

    def extract_lines(start_line, end_line)
      @lines[(start_line - 1)...end_line].map(&:rstrip).join("\n")
    end

    def slice_of(node)
      node.location.slice.to_s
    end
  end
end
