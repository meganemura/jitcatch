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
    ATTRIBUTE_MACROS = { attr_reader: [""], attr: [""], attr_writer: ["="], attr_accessor: ["", "="] }.freeze
    # The constant a member list is given to, and whether its members get writers.
    MEMBER_BUILDERS = { %i[Struct new] => true, %i[Data define] => false }.freeze
    # ActiveSupport::Concern blocks that define methods on the including
    # class, and whether those are class methods.
    CONCERN_BLOCKS = { included: false, prepended: false, class_methods: true }.freeze

    # `macro` is nil for a `def`. A method an `attr_*` macro or a Struct or
    # Data member list defines names that macro, and its source is the
    # one-name form (`attr_reader :seed`), so dropping one name from a shared
    # line does not read as a change to the names left on it.
    Method = Data.define(
      :file, :bare_name, :qualifier, :qualified, :kind, :visibility,
      :start_line, :end_line, :source, :params, :macro
    )
    Constant = Data.define(
      :file, :bare_name, :qualifier, :qualified, :start_line, :end_line, :source
    )
    Call = Data.define(:file, :bare_name, :line, :enclosing, :receiver)
    # What a call is sent to, as far as the source names it: the enclosing
    # object (`self`), a class or module itself (`singleton`), an instance
    # of one (`instance`), one of the constants a method of the same class
    # returns (`one_of`, with `const` the list), or a value only a run would
    # know (`unknown`).
    # `const` is the constant as written, or nil for the enclosing class.
    # An instance variable is an `instance` when every `Const.new` assigned
    # to it in the class names the same constant. A local variable is one
    # when every assignment to it in its method builds the same constant
    # and it is not a parameter.
    Receiver = Data.define(:kind, :const)
    UNKNOWN_RECEIVER = Receiver.new(kind: "unknown", const: nil)
    # A block given to an RSpec call: a `group` (describe, context), an
    # `example` (it, specify), or a `setup` (let, subject, before). Code in
    # an example or a setup block is referred to under `key`, and so are a
    # group's arguments.
    SpecBlock = Data.define(:kind, :key, :start_line, :end_line) do
      def covers?(line)
        (start_line..end_line).cover?(line)
      end
    end
    SPEC_KINDS = {
      "group" => %i[describe context feature example_group shared_examples shared_examples_for shared_context xdescribe xcontext fdescribe fcontext],
      "example" => %i[it specify example scenario its focus fit fspecify fexample xit xspecify xexample skip pending],
      "setup" => %i[let let! subject subject! before after around prepend_before append_before prepend_after append_after]
    }.flat_map { |kind, names| names.map { |name| [name, kind] } }.to_h.freeze
    # A local bound here can hold any value, so it types no call.
    LOCAL_BINDINGS = [
      Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RestParameterNode,
      Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode, Prism::KeywordRestParameterNode,
      Prism::BlockParameterNode, Prism::BlockLocalVariableNode, Prism::LocalVariableTargetNode,
      Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
    ].freeze
    SPEC_HELPERS = %i[let let! subject subject!].freeze
    DESCRIBED_METHOD = /\A[#.]([a-z_][\w]*[?!=]?)\z/

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
      @local_classes = Hash.new { |hash, key| hash[key] = [] }
      @helper_classes = Hash.new { |hash, key| hash[key] = [] }
      @parse_error = nil
      @spec_blocks = []
      @defined = Hash.new { |hash, key| hash[key] = [] }
      @described = []
      @returned = {}
    end

    def parse
      result = Prism.parse(@source)
      unless result.success?
        @parse_error = result.errors.map { |err| "L#{err.location.start_line}: #{err.message}" }.sort.join("; ")
        return self
      end

      scan_body(result.value, "", :public, false)
      @spec_helpers = spec_helper_names(result.value)
      walk(result.value, "", false, nil)
      type_instance_variables
      type_local_variables
      type_spec_helpers
      type_returned_receivers
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
      return (@references.values.flatten + receiver_names(@calls.map(&:enclosing))).uniq.sort unless start

      names_reached_from([start.qualified])
    end

    # The names an RSpec example starting on that line refers to: its own
    # block, the `let`, `subject`, and hook blocks of the groups around it,
    # the arguments of those groups, and the same-file helpers all of them
    # call. A group described as `"#total"` or `".build"` names that method.
    # Nil when no example starts on the line.
    def example_references(line)
      example = @spec_blocks.find { |block| block.kind == "example" && block.start_line == line }
      return nil unless example

      groups = @spec_blocks.select { |block| block.kind == "group" && block.covers?(line) }
      setups = @spec_blocks.select { |block|
        next false unless block.kind == "setup"

        parent = @spec_blocks.select { |group| group.kind == "group" && group.covers?(block.start_line) }.max_by(&:start_line)
        parent.nil? || groups.include?(parent)
      }
      names_reached_from([example, *groups, *setups].map(&:key))
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

    def names_reached_from(keys)
      helpers = @methods.group_by(&:bare_name).transform_values { |list| list.map(&:qualified) }
      @defined.each { |bare, names| helpers[bare] = (helpers.fetch(bare, []) + names).uniq }
      calls = @calls.group_by(&:enclosing)
      reached = keys.dup
      reached.each do |name|
        calls.fetch(name, []).each do |call|
          helpers.fetch(call.bare_name, []).each do |helper|
            reached << helper unless reached.include?(helper)
          end
        end
      end
      names = reached.flat_map { |name| @references.fetch(name, []) }
      (names + receiver_names(reached)).uniq.sort
    end

    # `Index.parse` for a call whose receiver the source names as the class
    # `Index` or as an instance of it, so a reader can tell it from another
    # class's `parse`. A constructor is already listed as `Owner.new`.
    def receiver_names(enclosings)
      @calls.filter_map do |call|
        receiver = call.receiver
        next unless enclosings.include?(call.enclosing) && receiver.const && call.bare_name != "new"

        case receiver.kind
        when "singleton" then "#{receiver.const}.#{call.bare_name}"
        when "instance" then "#{receiver.const}##{call.bare_name}"
        end
      end
    end

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
        record_members(stmt.superclass, nested) if stmt.is_a?(Prism::ClassNode) && stmt.superclass.is_a?(Prism::CallNode)
        scan_body(stmt, nested, :public, false)
        visibility
      when Prism::SingletonClassNode
        scan_body(stmt, qualifier, :public, true)
        visibility
      when Prism::IfNode, Prism::UnlessNode, Prism::ElseNode
        # A conditional in a class body defines what any branch defines,
        # read as if every branch ran in order, so a bare `private` in a
        # branch carries past the conditional as it does when that branch runs.
        visibility = Array(stmt.statements&.body).reduce(visibility) { |vis, inner| scan_statement(inner, qualifier, vis, singleton) }
        rest = %i[subsequent else_clause consequent].find { |name| stmt.respond_to?(name) }
        rest ? scan_statement(stmt.public_send(rest), qualifier, visibility, singleton) : visibility
      when Prism::DefNode
        record_method(stmt, qualifier, visibility, singleton)
        visibility
      when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        full = constant_target(stmt, qualifier)
        source, end_line = constant_header(stmt)
        record_constant(@constants, full, stmt.location.start_line, end_line, source)
        record_members(stmt.value, full) if stmt.value.is_a?(Prism::CallNode)
        block = value_block(stmt)
        scan_body(block, full, :public, false) if block
        visibility
      when Prism::CallNode
        return handle_visibility(stmt, qualifier, visibility, singleton) if visibility_modifier?(stmt)

        return handle_module_function(stmt, qualifier, visibility) if stmt.receiver.nil? && stmt.name == :module_function

        record_private_constants(stmt, qualifier) if stmt.name == :private_constant && (stmt.receiver.nil? || stmt.receiver.is_a?(Prism::SelfNode))

        if stmt.receiver.nil? && CONCERN_BLOCKS.key?(stmt.name) && stmt.block.is_a?(Prism::BlockNode)
          scan_body(stmt.block, qualifier, :public, CONCERN_BLOCKS.fetch(stmt.name))
          return visibility
        end

        handle_class_visibility(stmt, qualifier) if stmt.receiver.nil? && CLASS_VISIBILITY.key?(stmt.name)
        if stmt.receiver.nil? && ATTRIBUTE_MACROS.key?(stmt.name)
          record_attributes_as_methods(stmt, qualifier, visibility == :module_function ? :public : visibility, singleton)
        end
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
        when Prism::CallNode
          record_attributes_as_methods(arg, qualifier, stmt.name, singleton) if arg.receiver.nil? && ATTRIBUTE_MACROS.key?(arg.name)
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
        params: params,
        macro: nil
      )
    end

    def record_attributes_as_methods(stmt, qualifier, visibility, singleton)
      suffixes = ATTRIBUTE_MACROS.fetch(stmt.name)
      Array(stmt.arguments&.arguments).grep(Prism::SymbolNode).each do |arg|
        suffixes.each do |suffix|
          macro = suffix.empty? ? "attr_reader" : "attr_writer"
          record_generated(arg, qualifier, "#{arg.unescaped}#{suffix}", visibility, singleton, macro, "#{macro} :#{arg.unescaped}")
        end
      end
    end

    def record_members(call, qualifier)
      builder = const_name(call.receiver)
      writers = MEMBER_BUILDERS[[builder&.to_sym, call.name]]
      return if writers.nil?

      macro = "#{builder}.#{call.name}"
      Array(call.arguments&.arguments).grep(Prism::SymbolNode).each do |arg|
        source = "#{macro}(:#{arg.unescaped})"
        record_generated(arg, qualifier, arg.unescaped, :public, false, macro, source)
        record_generated(arg, qualifier, "#{arg.unescaped}=", :public, false, macro, source) if writers
      end
    end

    def record_generated(arg, qualifier, bare, visibility, singleton, macro, source)
      @methods << self.class::Method.new(
        file: @file,
        bare_name: bare,
        qualifier: qualifier.to_s,
        qualified: self.class.qualify(qualifier, bare, singleton),
        kind: singleton ? "singleton" : "instance",
        visibility: visibility.to_s,
        start_line: arg.location.start_line,
        end_line: arg.location.start_line,
        source: source,
        params: bare.end_with?("=") ? "value" : "",
        macro: macro
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

    def type_local_variables
      @calls.map! do |call|
        next call unless call.receiver.kind == "local"

        built = @local_classes[[call.enclosing, call.receiver.const]].uniq
        typed = built.size == 1 && built.first
        call.with(receiver: typed ? Receiver.new(kind: "instance", const: typed) : UNKNOWN_RECEIVER)
      end
    end

    # `let(:cart) { Cart.new }` makes `cart.total` a call on a Cart, as a
    # local variable would. A name defined twice, in two groups, types none.
    def type_spec_helpers
      @calls.map! do |call|
        next call unless call.receiver.kind == "helper"

        built = @helper_classes[call.receiver.const].uniq
        typed = built.size == 1 && built.first
        call.with(receiver: typed ? Receiver.new(kind: "instance", const: typed) : UNKNOWN_RECEIVER)
      end
    end

    # `emitter_for(format).render` sends `render` to whatever `emitter_for`
    # returns. When that method of the same class returns only constants (and
    # nil), the call goes to one of them.
    def type_returned_receivers
      @calls.map! do |call|
        next call unless call.receiver.kind == "returned"

        qualifier, sep, _bare = self.class.split_qualified(call.enclosing.to_s)
        names = [sep == ".", sep != "."].map { |singleton| self.class.qualify(qualifier, call.receiver.const, singleton) }
        consts = @returned.values_at(*names).compact.first.to_a.uniq
        call.with(receiver: consts.empty? ? UNKNOWN_RECEIVER : Receiver.new(kind: "one_of", const: consts))
      end
    end

    # The constants a method body can return, or nil when it can return
    # anything else. A `nil` branch adds none.
    def returned_constants(node)
      case node
      when nil, Prism::NilNode
        []
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        [const_name(node)]
      when Prism::StatementsNode
        returned_constants(node.body.last)
      when Prism::ParenthesesNode
        returned_constants(node.body)
      when Prism::ElseNode, Prism::WhenNode
        returned_constants(node.statements)
      when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode
        branches = (node.compact_child_nodes - [node.predicate]).map { |branch| returned_constants(branch) }
        branches.all? ? branches.flatten : nil
      end
    end

    def returns?(node)
      return false if node.nil? || node.is_a?(Prism::DefNode)

      node.is_a?(Prism::ReturnNode) || node.compact_child_nodes.any? { |child| returns?(child) }
    end

    # The constants a value builds with `Const.new`, through `a || b`,
    # `c ? a : b`, and parentheses.
    def built_constants(node)
      case node
      when Prism::CallNode
        owner = constructor_owner(node) || described_owner(node)
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
        @defined[node.name.to_s] << qname unless @defined[node.name.to_s].include?(qname)
        @returned[qname] = returned_constants(node.body) unless returns?(node.body)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, qname) }
      when Prism::CallNode
        return walk_spec_block(node, qualifier, singleton_context, enclosing) if spec_block?(node)

        if node.name
          @calls << self.class::Call.new(
            file: @file,
            bare_name: node.name.to_s,
            line: node.location.start_line,
            enclosing: enclosing,
            receiver: receiver_of(node.receiver)
          )
          refer(enclosing, node.name) unless spec_helper_call?(node)
          owner = constructor_owner(node) || described_owner(node)
          refer(enclosing, "#{owner.split("::").last}.new") if owner
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
        refer(enclosing, name_of(node))
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when Prism::SymbolNode
        refer(enclosing, node.unescaped)
      when Prism::LocalVariableWriteNode
        built = built_constants(node.value).uniq
        @local_classes[[enclosing, node.name.to_s]] << (built.size == 1 ? built.first : nil)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when *LOCAL_BINDINGS
        @local_classes[[enclosing, node.name.to_s]] << nil if node.name
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode
        @ivar_classes[[qualifier.to_s, node.name.to_s]].concat(built_constants(node.value))
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      else
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      end
    end

    def spec_block?(node)
      return false unless node.block.is_a?(Prism::BlockNode) && SPEC_KINDS.key?(node.name)

      node.receiver.nil? || (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :RSpec)
    end

    def walk_spec_block(node, qualifier, singleton_context, enclosing)
      kind = SPEC_KINDS.fetch(node.name)
      block = SpecBlock.new(kind: kind, key: "#{kind}:#{node.location.start_line}", start_line: node.location.start_line, end_line: node.location.end_line)
      @spec_blocks << block
      record_spec_helper(node) if SPEC_HELPERS.include?(node.name)
      arguments = Array(node.arguments&.arguments)
      arguments.each { |arg| walk(arg, qualifier, singleton_context, block.key) unless spec_helper_name?(node, arg) }
      described = kind == "group" ? arguments.first : nil
      if described.is_a?(Prism::StringNode) && (match = described.unescaped.match(DESCRIBED_METHOD))
        refer(block.key, match[1])
      end
      return walk(node.block, qualifier, singleton_context, block.key) unless kind == "group"

      @described.push(const_name(described) || @described.last)
      walk(node.block, qualifier, singleton_context, enclosing)
      @described.pop
    end

    # `let(:result)` and `subject(:result)` name a helper of the spec, so the
    # symbol and a bare `result` call refer to the spec's own helper, not to
    # a method `result` of the code under test.
    def spec_helper_names(node)
      own = node.is_a?(Prism::CallNode) && spec_helper_name?(node, node.arguments&.arguments&.first) ? [node.arguments.arguments.first.unescaped] : []
      own << "subject" if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block && %i[subject subject!].include?(node.name)
      own + node.compact_child_nodes.flat_map { |child| spec_helper_names(child) }
    end

    # An unnamed `subject` is called as `subject`, and a named one answers
    # to both names.
    def record_spec_helper(node)
      first = node.arguments&.arguments&.first
      names = first.is_a?(Prism::SymbolNode) ? [first.unescaped] : []
      names << "subject" if node.name.start_with?("subject")
      built = built_constants(node.block.body).uniq
      names.each { |name| @helper_classes[name] << (built.size == 1 ? built.first : nil) }
    end

    def spec_helper_name?(node, arg)
      SPEC_HELPERS.include?(node.name) && node.receiver.nil? && arg.is_a?(Prism::SymbolNode) && node.arguments.arguments.first.equal?(arg)
    end

    def spec_helper_call?(node)
      node.receiver.nil? && node.arguments.nil? && @spec_helpers.include?(node.name.to_s)
    end

    # `described_class.new` builds the constant the enclosing group describes.
    def described_owner(node)
      return nil unless node.name == :new && node.receiver.is_a?(Prism::CallNode)
      return nil unless node.receiver.name == :described_class && node.receiver.receiver.nil?

      @described.last
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
      when Prism::LocalVariableReadNode
        Receiver.new(kind: "local", const: node.name.to_s)
      when Prism::CallNode
        if node.name == :described_class && node.receiver.nil?
          return @described.last ? Receiver.new(kind: "singleton", const: @described.last) : UNKNOWN_RECEIVER
        end

        inner = receiver_of(node.receiver)
        if node.name == :class && inner.kind == "self" && !node.receiver.nil?
          Receiver.new(kind: "singleton", const: nil)
        elsif node.name == :new && inner.kind == "singleton"
          Receiver.new(kind: "instance", const: inner.const)
        elsif node.name == :new && inner.kind == "self"
          Receiver.new(kind: "instance", const: nil)
        elsif node.receiver.nil? && @spec_helpers.include?(node.name.to_s)
          Receiver.new(kind: "helper", const: node.name.to_s)
        elsif inner.kind == "self"
          Receiver.new(kind: "returned", const: node.name.to_s)
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
      name_of(receiver).to_s if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
    end

    # Prism 0.19, the default on Ruby 3.3, has no ConstantPathNode#name: the
    # last segment is a ConstantReadNode in `child`, which Prism 1.x deprecates.
    # `full_name` and the source text after `::` are not the same on both.
    def name_of(node)
      node.respond_to?(:name) ? node.name : node.child.name
    end

    def const_name(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantWriteNode
        node.name.to_s
      when Prism::ConstantPathNode
        parent = node.parent ? const_name(node.parent) : nil
        [parent, name_of(node).to_s].compact.reject(&:empty?).join("::")
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
