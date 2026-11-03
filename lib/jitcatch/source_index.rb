# frozen_string_literal: true

require "prism"

module JitCatch
  # Indexes methods, constants, and calls in one Ruby file.
  # Dynamic definitions (`define_method`, `class_eval`) are not indexed.
  class SourceIndex
    VISIBILITY = %i[public private protected].freeze
    CLASS_VISIBILITY = { private_class_method: :private, public_class_method: :public }.freeze
    # A symbol passed to these names a Hash key, not a method, so
    # `snap[:total]` does not mention a method `total`.
    HASH_KEY_CALLS = %i[[] []= fetch dig key? has_key? values_at fetch_values].freeze
    # These name a method by their first argument, as a symbol or a string.
    REFLECTIVE_CALLS = %i[send __send__ public_send method public_method respond_to?].freeze

    Method = Data.define(
      :file, :bare_name, :qualifier, :qualified, :kind, :visibility,
      :start_line, :end_line, :source, :params
    )
    Constant = Data.define(
      :file, :bare_name, :qualifier, :qualified, :start_line, :end_line, :source
    )
    Call = Data.define(:file, :bare_name, :line, :enclosing, :receiver)
    # What a call is sent to, as far as the source names it: the enclosing
    # object (`self`), a class or module itself (`singleton`), an instance
    # of one (`instance`), or a value only a run would know (`unknown`).
    # `const` is the constant as written, or nil for the enclosing class.
    # An instance variable is an `instance` when every `Const.new` assigned
    # to it in the class names the same constant.
    Receiver = Data.define(:kind, :const)
    UNKNOWN_RECEIVER = Receiver.new(kind: "unknown", const: nil)

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
      @references = Hash.new { |hash, key| hash[key] = [] }
      @ivar_classes = Hash.new { |hash, key| hash[key] = [] }
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
      type_instance_variables
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

    # The names a method refers to in code, with the same-file helpers it
    # calls: method calls, constant reads, and symbols. A constructor call
    # is also listed as `Owner.new`. Strings and comments are not read, except
    # a plain string that a REFLECTIVE_CALLS call takes first. A symbol that
    # keys a Hash is not listed. When the file defines no method by that
    # name, the whole file is read.
    def referenced_names(qualified)
      start = @methods.find { |method| method.qualified == qualified }
      return @references.values.flatten.uniq.sort unless start

      by_bare = @methods.group_by(&:bare_name)
      calls = @calls.group_by(&:enclosing)
      reached = [start.qualified]
      reached.each do |name|
        calls.fetch(name, []).each do |call|
          by_bare.fetch(call.bare_name, []).each do |helper|
            reached << helper.qualified unless reached.include?(helper.qualified)
          end
        end
      end
      reached.flat_map { |name| @references.fetch(name, []) }.uniq.sort
    end

    # Code outside the namespace cannot name a private constant, so no method
    # under it is an entry point, whatever its own visibility says. A revision
    # passes the names from all its files, since a namespace can be reopened.
    def self.hide_private_constants(methods, names)
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
    def type_instance_variables
      @calls.map! do |call|
        next call unless call.receiver.kind == "ivar"

        qualifier, _sep, _bare = self.class.split_qualified(call.enclosing.to_s)
        named = @ivar_classes[[qualifier, call.receiver.const]].uniq
        call.with(receiver: named.size == 1 ? Receiver.new(kind: "instance", const: named.first) : UNKNOWN_RECEIVER)
      end
    end

    # The constants a value builds with `Const.new`, through `a || b`,
    # `c ? a : b`, and parentheses.
    def built_constants(node)
      case node
      when Prism::CallNode
        owner = constructor_owner(node)
        owner ? [owner] : []
      when Prism::OrNode, Prism::AndNode
        built_constants(node.left) + built_constants(node.right)
      when Prism::IfNode, Prism::UnlessNode
        (node.compact_child_nodes - [node.predicate]).flat_map { |branch| built_constants(branch) }
      when Prism::ElseNode
        built_constants(node.statements)
      when Prism::ParenthesesNode
        built_constants(node.body)
      when Prism::StatementsNode
        built_constants(node.body.last)
      else
        []
      end
    end

    def rename_module_function_callers
      renamed = @module_functions.to_h { |name| [name, name.sub(/#(?=[^#]*\z)/, ".")] }
      @calls.map! { |call| renamed.key?(call.enclosing) ? call.with(enclosing: renamed[call.enclosing]) : call }
      renamed.each { |from, to| @references[to] = @references.delete(from) if @references.key?(from) }
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
            enclosing: enclosing,
            receiver: receiver_of(node.receiver)
          )
          refer(enclosing, node.name)
          owner = constructor_owner(node)
          refer(enclosing, "#{owner}.new") if owner
          named = reflective_name(node)
          refer(enclosing, named) if named
        end
        node.compact_child_nodes.each do |child|
          children = child.is_a?(Prism::ArgumentsNode) && HASH_KEY_CALLS.include?(node.name) ? child.arguments.grep_v(Prism::SymbolNode) : [child]
          children.each { |arg| walk(arg, qualifier, singleton_context, enclosing) }
        end
      when Prism::AssocNode
        walk(node.key, qualifier, singleton_context, enclosing) unless node.key.is_a?(Prism::SymbolNode)
        walk(node.value, qualifier, singleton_context, enclosing) if node.value
      when Prism::CallOperatorWriteNode, Prism::CallAndWriteNode, Prism::CallOrWriteNode
        refer(enclosing, node.read_name)
        refer(enclosing, node.write_name)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when Prism::CallTargetNode, Prism::ConstantReadNode, Prism::ConstantPathNode
        refer(enclosing, node.name)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when Prism::SymbolNode
        refer(enclosing, node.unescaped)
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode
        @ivar_classes[[qualifier.to_s, node.name.to_s]].concat(built_constants(node.value))
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      else
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      end
    end

    def refer(enclosing, name)
      @references[enclosing] << name.to_s
    end

    def reflective_name(node)
      return nil unless REFLECTIVE_CALLS.include?(node.name)

      first = node.arguments&.arguments&.first
      first.unescaped if first.is_a?(Prism::StringNode)
    end

    def receiver_of(node)
      case node
      when nil, Prism::SelfNode
        Receiver.new(kind: "self", const: nil)
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Receiver.new(kind: "singleton", const: const_name(node))
      when Prism::InstanceVariableReadNode
        Receiver.new(kind: "ivar", const: node.name.to_s)
      when Prism::CallNode
        inner = receiver_of(node.receiver)
        if node.name == :class && inner.kind == "self" && !node.receiver.nil?
          Receiver.new(kind: "singleton", const: nil)
        elsif node.name == :new && inner.kind == "singleton"
          Receiver.new(kind: "instance", const: inner.const)
        elsif node.name == :new && inner.kind == "self"
          Receiver.new(kind: "instance", const: nil)
        else
          UNKNOWN_RECEIVER
        end
      else
        UNKNOWN_RECEIVER
      end
    end

    def constructor_owner(node)
      return nil unless node.name == :new

      receiver = node.receiver
      receiver.name.to_s if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
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
