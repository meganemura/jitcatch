# frozen_string_literal: true
# rbs_inline: enabled

require "prism"

module JitCatch
  # Indexes methods, constants, and calls in one Ruby file.
  # Dynamic definitions (`define_method`, `class_eval`) are not indexed.
  class SourceIndex
    VISIBILITY = %i[public private protected].freeze #: Array[Symbol]
    CLASS_VISIBILITY = { private_class_method: :private, public_class_method: :public }.freeze #: Hash[Symbol, Symbol]
    # A symbol passed to these names a Hash key, not a method, so
    # `snap[:total]` does not mention a method `total`.
    HASH_KEY_CALLS = %i[[] []= fetch dig key? has_key? values_at fetch_values].freeze #: Array[Symbol]
    # These name a method by their first argument, as a symbol or a string.
    REFLECTIVE_CALLS = %i[send __send__ public_send method public_method respond_to?].freeze #: Array[Symbol]
    SEND_CALLS = %i[send __send__ public_send].freeze #: Array[Symbol]
    # Exception#message and the messages built on it call to_s, the method an
    # error class overrides to say what went wrong.
    MESSAGE_CALLS = %i[message full_message detailed_message].freeze #: Array[Symbol]
    # A relative path with a directory part and no spaces: `exe/tool`.
    PATH_LIKE = %r{\A(?:\.\.?/)*[\w.-]+(?:/[\w.-]+)+\z} #: Regexp
    # Minitest assertions and expectations, RSpec matchers, and the string
    # predicates a test asserts on.
    COMPARING_CALL = /\A(?:assert|refute|must|wont)(?:_\w+)?\z|\A(?:eq|eql|equal|include|match|start_with|end_with|include\?|match\?|start_with\?|end_with\?|==|=~)\z/ #: Regexp
    ATTRIBUTE_MACROS = { attr_reader: [""], attr: [""], attr_writer: ["="], attr_accessor: ["", "="] }.freeze #: Hash[Symbol, Array[String]]
    # The constant a member list is given to, and whether its members get writers.
    MEMBER_BUILDERS = { %i[Struct new] => true, %i[Data define] => false }.freeze #: Hash[Array[Symbol?], bool]
    # Grape's route verbs, and the blocks that add a segment to the path of
    # the endpoints inside them. `route_param :id` adds `:id`.
    ENDPOINT_VERBS = %i[get post put patch delete head options].freeze #: Array[Symbol]
    PATH_BLOCKS = %i[resource resources namespace group segment route_param].freeze #: Array[Symbol]
    # `desc` and `params` describe the endpoint that follows them.
    ENDPOINT_DESCRIPTIONS = %i[desc params].freeze #: Array[Symbol]
    # A request path segment the test computes, as `#{thing.id}`.
    COMPUTED_SEGMENT = "*" #: String
    ROUTE_HELPER = /\A\w+_(?:path|url)\z/ #: Regexp
    # A class is an API when its superclass is Grape's, or an app's own base
    # class named like one (`BaseAPI`, `Api::Base` is not).
    API_SUPERCLASS = /(?:\A|::)(?:Grape::API(?:::Instance)?|\w*(?:API|Api))\z/ #: Regexp
    # ActiveSupport::Concern blocks that define methods on the including
    # class, and whether those are class methods.
    CONCERN_BLOCKS = { included: false, prepended: false, class_methods: true }.freeze #: Hash[Symbol, bool]

    # `macro` is nil for a `def`. A method an `attr_*` macro or a Struct or
    # Data member list defines names that macro, and its source is the
    # one-name form (`attr_reader :seed`), so dropping one name from a shared
    # line does not read as a change to the names left on it.
    Method = Data.define(
      :file, #: String
      :bare_name, #: String
      :qualifier, #: String
      :qualified, #: String
      :kind, #: String
      :visibility, #: String
      :start_line, #: Integer
      :end_line, #: Integer
      :source, #: String
      :params, #: String
      :macro #: String?
    )
    Constant = Data.define(
      :file, #: String
      :bare_name, #: String
      :qualifier, #: String
      :qualified, #: String
      :start_line, #: Integer
      :end_line, #: Integer
      :source #: String
    )
    # `enclosing` is the method, spec block, or endpoint the call is in, or
    # nil at the top of a file.
    Call = Data.define(
      :file, #: String
      :bare_name, #: String
      :line, #: Integer
      :enclosing, #: String?
      :receiver #: Receiver
    )
    # What a call is sent to, as far as the source names it: the enclosing
    # object (`self`), a class or module itself (`singleton`), an instance
    # of one (`instance`), one of the constants a method of the same class
    # returns (`one_of`, with `const` the list), or a value only a run would
    # know (`unknown`), or a value the source does not type that Rails would
    # name after its model (`named`, with `const` the name in snake case).
    # `const` is the constant as written, or nil for the enclosing class.
    # An instance variable is an `instance` when every `Const.new` assigned
    # to it in the class names the same constant, and `named` when none
    # does. A local variable is an `instance` when every assignment to it in
    # its method builds the same constant, and `named` when none builds
    # one, as for a parameter. A reader that `belongs_to` or `has_one`
    # declares is an `instance` of the model it names. A local that every
    # assignment in its method sets to a lambda or a proc literal, or that
    # `&block` binds, is a `proc`: its `call` runs that block, never a
    # method the repository defines.
    # `const` is a String, or for `one_of` an Array of them, or nil.
    Receiver = Data.define(
      :kind, #: String
      :const #: untyped
    )
    UNKNOWN_RECEIVER = Receiver.new(kind: "unknown", const: nil) #: Receiver
    PROC_RECEIVER = Receiver.new(kind: "proc", const: nil) #: Receiver
    # A block given to an RSpec call: a `group` (describe, context), an
    # `example` (it, specify), or a `setup` (let, subject, before). Code in
    # an example or a setup block is referred to under `key`, and so are a
    # group's arguments.
    SpecBlock = Data.define(
      :kind, #: String
      :key, #: String
      :start_line, #: Integer
      :end_line #: Integer
    ) do
      # Steep reads a def in this block as a method of SourceIndex, so it
      # checks the method against the declaration below instead.
      # steep:ignore:start
      def covers?(line)
        (start_line..end_line).cover?(line)
      end
      # steep:ignore:end
    end
    SPEC_KINDS = {
      "group" => %i[describe context feature example_group shared_examples shared_examples_for shared_context xdescribe xcontext fdescribe fcontext],
      "example" => %i[it specify example scenario its focus fit fspecify fexample xit xspecify xexample skip pending],
      "setup" => %i[let let! subject subject! before after around prepend_before append_before prepend_after append_after]
    }.flat_map { |kind, names| names.map { |name| [name, kind] } }.to_h.freeze #: Hash[Symbol, String]
    # A local bound here can hold any value, so it types no call.
    LOCAL_BINDINGS = [
      Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RestParameterNode,
      Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode, Prism::KeywordRestParameterNode,
      Prism::BlockParameterNode, Prism::BlockLocalVariableNode, Prism::LocalVariableTargetNode,
      Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
    ].freeze #: Array[singleton(Prism::Node)]
    SPEC_HELPERS = %i[let let! subject subject!].freeze #: Array[Symbol]
    # The Active Record macros that define a reader returning one record.
    ASSOCIATION_READERS = %i[belongs_to has_one].freeze #: Array[Symbol]
    DESCRIBED_METHOD = /\A[#.]([a-z_][\w]*[?!=]?)\z/ #: Regexp
    # FactoryBot's calls that build an object, so run its class's
    # `initialize`. `attributes_for` builds a Hash.
    FACTORY_CALLS = %i[build build_list build_pair build_stubbed build_stubbed_list build_stubbed_pair create create_list create_pair].freeze #: Array[Symbol]

    # The calls on an Active Record model that run a method its class body
    # names in a callback or a validation, by Rails's own rules: `.create`
    # is sent to the class, `#save` to a record. `validates` takes its
    # positional symbols as attributes, so only its `if:` and `unless:`
    # name methods.
    creating = %w[.create .create! #save #save!]
    updating = %w[#save #save! #update #update!]
    saving = (creating + updating).uniq
    destroying = %w[#destroy #destroy!]
    RECORD_CALLBACKS = {
      saving + %w[#valid? #invalid? #validate #validate!] => %i[validate validates before_validation after_validation],
      saving => %i[before_save around_save after_save after_save_commit],
      creating => %i[before_create around_create after_create after_create_commit],
      updating => %i[before_update around_update after_update after_update_commit],
      destroying => %i[before_destroy around_destroy after_destroy after_destroy_commit],
      saving + destroying => %i[after_commit after_rollback]
    }.flat_map { |calls, macros| macros.map { |macro| [macro, calls.sort.freeze] } }.to_h.freeze #: Hash[Symbol, Array[String]]
    CALLBACK_CONDITIONS = %w[if unless].freeze #: Array[String]
    # Rails reads `on:` only on a validation and on a commit or rollback
    # callback. A context of its own (`on: :publish`) runs only from a
    # call that takes one: `valid?(:publish)` or `save(context: :publish)`.
    CONTEXT_MACROS = %i[validate validates before_validation after_validation after_commit after_rollback].freeze #: Array[Symbol]
    validating = %w[#valid? #invalid? #validate #validate!]
    CONTEXT_CALLS = { "create" => creating + validating, "update" => updating + validating, "destroy" => destroying }.freeze #: Hash[String, Array[String]]
    OWN_CONTEXT_CALLS = (%w[#save #save!] + validating).freeze #: Array[String]
    # FactoryBot's calls that save what they build, and so run its save
    # callbacks. The other FACTORY_CALLS only build.
    SAVING_FACTORY_CALLS = %w[create create_list create_pair].freeze #: Array[String]

    # A class header's superclass as written, and the namespace the header
    # is in, which the name is looked up from.
    Superclass = Data.define(
      :qualified, #: String
      :written, #: String
      :scope #: String
    )
    # One method a callback or validation line in a class body names.
    # `declared` is the line in short (`after_save :count_save`,
    # `validates if: :checked?`). `contexts` holds the `on:` symbols as
    # written, or nil when the line names none.
    Callback = Data.define(
      :qualifier, #: String
      :macro, #: String
      :method, #: String
      :declared, #: String
      :contexts #: Array[String]?
    ) do
      # The record calls, as `.create` or `#save`, that can run it.
      # steep:ignore:start
      def calls
        all = RECORD_CALLBACKS.fetch(macro.to_sym)
        return all if contexts.nil? || !CONTEXT_MACROS.include?(macro.to_sym)

        all & contexts.flat_map { |context| CONTEXT_CALLS.fetch(context, OWN_CONTEXT_CALLS) }
      end
      # steep:ignore:end
    end

    # One `require_relative` call with one argument. `path` is nil when the
    # source does not settle it: only a string literal, or File.join of
    # string literals, does.
    RelativeRequire = Data.define(
      :path, #: String?
      :line #: Integer
    )

    # @rbs!
    #   # Data.define's block defines these; rbs-inline reads only the members,
    #   # and Steep does not check those blocks.
    #   class SpecBlock
    #     def covers?: (Integer line) -> bool
    #   end
    #
    #   class Callback
    #     def calls: () -> Array[String]
    #   end

    attr_reader :methods #: Array[Method]
    attr_reader :constants #: Array[Constant]
    attr_reader :namespaces #: Array[Constant]
    attr_reader :superclasses #: Array[Superclass]
    attr_reader :callbacks #: Array[Callback]
    attr_reader :calls #: Array[Call]
    attr_reader :private_constants #: Array[String]
    attr_reader :parse_error #: String?

    # @rbs @script: bool
    # @rbs @source: String
    # @rbs @lines: Array[String]
    # @rbs @file: String
    # @rbs @module_functions: Array[String]
    # @rbs @new_visibility: Hash[String, String]
    # @rbs @references: Hash[String?, Array[String]]
    # @rbs @ivar_classes: Hash[[String, String], Array[String]]
    # @rbs @local_classes: Hash[[String?, String], Array[Array[String]]]
    # @rbs @local_procs: Hash[[String?, String], Array[bool]]
    # @rbs @helper_classes: Hash[String, Array[String?]]
    # @rbs @spec_blocks: Array[SpecBlock]
    # @rbs @defined: Hash[String, Array[String]]
    # @rbs @described: Array[String?]
    # @rbs @returned: Hash[String, Array[String]?]
    # @rbs @association_classes: Hash[String, String]
    # @rbs @symbol_lists: Hash[String, Array[Prism::SymbolNode]]
    # @rbs @paths: Hash[String?, Array[String]]
    # @rbs @compared: Hash[Integer, bool]
    # @rbs @factory_calls: Hash[String?, Array[[String, String, Array[String]]]]
    # @rbs @endpoints: Hash[Integer, String]
    # @rbs @string_constants: Hash[String, String]
    # @rbs @spec_helpers: Array[String]

    # The classes whose `new` the file made private, so no test builds them
    # with it. `new` is inherited, never defined, so no Method carries it.
    #: () -> Array[String]
    def hidden_new
      @new_visibility.filter_map { |qualifier, visibility| qualifier unless visibility == "public" }
    end

    # `script: true` reads the file as an executable, such as `exe/tool`:
    # its top-level code is one method of kind `script`, named by
    # `script_name`, whose calls are that method's.
    #: (String? source, file: String, ?script: bool) -> SourceIndex
    def self.parse(source, file:, script: false)
      new(source, file, script).parse
    end

    # The executables a gem or an app ships, which carry no `.rb` suffix.
    SCRIPT_PATH = %r{\A(?:exe|bin)/[\w-]+\z} #: Regexp

    #: (String path) -> bool
    def self.script_path?(path)
      SCRIPT_PATH.match?(path)
    end

    # A file whose first line runs Ruby.
    #: (String? text) -> bool
    def self.ruby_script?(text)
      text.to_s.lines.first.to_s.match?(/\A#!.*\bruby\b/)
    end

    #: (String file) -> String
    def self.script_name(file)
      "#{file} <main>"
    end

    # Every require_relative of a source, wherever it is written. Only a
    # run reads these, for its few candidate files, so the parse of every
    # repository file does not pay for the walk.
    #: (String? source) -> Array[RelativeRequire]
    def self.relative_requires(source)
      found = [] #: Array[RelativeRequire]
      pending = [Prism.parse(source.to_s).value] #: Array[untyped]
      while (node = pending.pop)
        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :require_relative && node.arguments&.arguments&.size == 1
          found << RelativeRequire.new(path: settled_path(node.arguments&.arguments&.first), line: node.location.start_line)
        end
        pending.concat(node.compact_child_nodes)
      end
      found.sort_by(&:line)
    end

    #: (Prism::Node? node) -> String?
    def self.settled_path(node)
      return node.unescaped if node.is_a?(Prism::StringNode)
      return nil unless node.is_a?(Prism::CallNode) && node.name == :join && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :File

      parts = Array(node.arguments&.arguments) #: Array[untyped]
      parts.all?(Prism::StringNode) && !parts.empty? ? File.join(*parts.map(&:unescaped)) : nil
    end

    #: (String? source, String file, ?bool script) -> void
    def initialize(source, file, script = false)
      @script = script
      @source = source.to_s.gsub("\r\n", "\n")
      @lines = @source.lines
      @file = file.tr("\\", "/")
      @methods = []
      @constants = []
      @namespaces = []
      @superclasses = []
      @callbacks = []
      @module_functions = []
      @private_constants = []
      @new_visibility = {}
      @calls = []
      @references = Hash.new { |hash, key| hash[key] = [] }
      @ivar_classes = Hash.new { |hash, key| hash[key] = [] }
      @local_classes = Hash.new { |hash, key| hash[key] = [] }
      @local_procs = Hash.new { |hash, key| hash[key] = [] }
      @helper_classes = Hash.new { |hash, key| hash[key] = [] }
      @parse_error = nil
      @spec_blocks = []
      @defined = Hash.new { |hash, key| hash[key] = [] }
      @described = []
      @returned = {}
      @association_classes = {}
      @symbol_lists = {}
      @paths = Hash.new { |hash, key| hash[key] = [] }
      @compared = {}
      @factory_calls = Hash.new { |hash, key| hash[key] = [] }
      @endpoints = {}
    end

    #: () -> self
    def parse
      result = Prism.parse(@source)
      unless result.success?
        @parse_error = result.errors.map { |err| "L#{err.location.start_line}: #{err.message}" }.sort.join("; ")
        return self
      end

      @string_constants = string_constants(result.value)
      scan_body(result.value, "", :public, false)
      main = @script ? record_script(result.value) : nil
      @spec_helpers = spec_helper_names(result.value)
      walk(result.value, "", false, main)
      type_local_variables
      type_instance_variables
      type_spec_helpers
      type_returned_receivers
      rename_module_function_callers
      @methods = self.class.hide_private_constants(@methods, @private_constants)
      self
    end

    #: (String? qualifier, String bare, bool singleton) -> String
    def self.qualify(qualifier, bare, singleton)
      sep = singleton ? "." : "#"
      qualifier.to_s.empty? ? "#{sep}#{bare}" : "#{qualifier}#{sep}#{bare}"
    end

    # How a test that builds an object from the factory `name` mentions it:
    # `create(:loan)` when the call saves the record, `build(:loan)` when it
    # does not, and `create(:loan, :cosigned)` with a trait.
    #: (String? name, String | Symbol call, ?String? trait) -> String
    def self.factory_mention(name, call, trait = nil)
      verb = SAVING_FACTORY_CALLS.include?(call.to_s) ? "create" : "build"
      trait ? "#{verb}(:#{name}, :#{trait})" : "#{verb}(:#{name})"
    end

    #: (String name) -> bool
    def self.unsaved_mention?(name)
      name.start_with?("build(:")
    end

    # The bare names of the record calls (`#save!`) among `calls`.
    #: (Array[String] calls) -> Array[String]
    def self.record_calls(calls)
      calls.filter_map do |call|
        owner, sep, bare = split_qualified(call)
        bare if sep == "#" && !owner.empty?
      end
    end

    # Whether a test that names `names` makes one of `record_calls` on any
    # receiver: the record `build(:loan)` returns sits in a local the source
    # does not type, so the receiver cannot be checked. RSpec's `be_valid`
    # calls `valid?`.
    #: (Array[String] names, Array[String] record_calls) -> bool
    def self.saves_or_validates?(names, record_calls)
      names.any? do |name|
        bare = split_qualified(name).last
        record_calls.include?(bare) || record_calls.include?("#{bare.delete_prefix("be_")}?")
      end
    end

    # Whether a call a test writes (`Loan.create!`, `Loan#save`) is the
    # call `call` names. The written owner can be shorter or longer than
    # the call's by whole namespace segments, as `Loan` is written inside
    # `module Shop` for `Shop::Loan`.
    #: (String written, String call) -> bool
    def self.names_call?(written, call)
      return true if written == call

      owner, sep, bare = split_qualified(written)
      call_owner, call_sep, call_bare = split_qualified(call)
      return false if sep != call_sep || bare != call_bare

      call_owner.end_with?("::#{owner}") || owner.end_with?("::#{call_owner}")
    end

    # The model Rails names a record after: `line_item` is a LineItem.
    #: (String snake) -> String
    def self.model_name(snake)
      snake.split("_").map(&:capitalize).join
    end

    # Whether a request a test sends (`POST /v1/things/7/refresh`) reaches
    # an endpoint (`POST /things/:id/refresh`): the same verb, and the
    # request's path ends in the endpoint's segments, a `:param` matching
    # any one. Leading segments are a mount point the API class does not name.
    # A `*` segment is a part the test computes, which matches any one; a
    # path that starts with one computes its mount point, so it can be
    # shorter than the endpoint's. An endpoint whose path the source
    # computes matches no request.
    #: (String written, String endpoint) -> bool
    def self.endpoint_call?(written, endpoint)
      verb, path = written.split(" ", 2)
      endpoint_verb, endpoint_path = endpoint.split(" ", 2)
      return false unless verb == endpoint_verb && path && endpoint_path
      return false if computed_path?(endpoint)

      sent = path.split("/").reject(&:empty?)
      open_mount = sent.first == COMPUTED_SEGMENT
      sent = sent.drop(1) if open_mount
      wanted = endpoint_path.split("/").reject(&:empty?)
      return false if sent.size < wanted.size && !open_mount

      size = [sent.size, wanted.size].min
      sent.last(size).zip(wanted.last(size)).all? { |part, want| part == COMPUTED_SEGMENT || want.to_s.start_with?(":") || part == want }
    end

    #: (String name) -> bool
    def self.endpoint?(name)
      name.match?(%r{\A[A-Z]+ [/*]})
    end

    # A request sent to a path helper, as `post things_path` is.
    #: (String name) -> bool
    def self.route_helper_request?(name)
      name.match?(/\A[A-Z]+ \w+_path\z/)
    end

    #: (String name) -> bool
    def self.request?(name)
      endpoint?(name) || route_helper_request?(name)
    end

    # An endpoint whose path holds a part the source computes, written as
    # that part's source in braces.
    #: (String name) -> bool
    def self.computed_path?(name)
      name.match?(/\A[A-Z]+ \S*\{/)
    end

    # The owner, the separator (`#` or `.`), and the bare name.
    #: (String qname) -> [String, String, String]
    def self.split_qualified(qname)
      if (idx = qname.rindex("#"))
        [qname[0...idx], "#", qname[(idx + 1)..]] #: [String, String, String]
      elsif (idx = qname.rindex("."))
        [qname[0...idx], ".", qname[(idx + 1)..]] #: [String, String, String]
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
    #: (String? qualified) -> Array[String]
    def referenced_names(qualified)
      start = @methods.find { |method| method.qualified == qualified }
      return (@references.values.flatten + receiver_names(@calls.map(&:enclosing)) + factory_names(@factory_calls.keys)).uniq.sort unless start

      names_reached_from([start.qualified])
    end

    # The method names that the test, the example on that line, or the
    # whole file sends only to constants it names (`File.write`), each with
    # those constants, in the same scope as the names it refers to.
    #: (String qualified, Integer? line) -> Hash[String, Array[String]]
    def names_sent_only_to_constants(qualified, line)
      keys = line ? example_keys(line) : [] #: Array[String]
      keys = [qualified] if keys.empty? && @methods.any? { |method| method.qualified == qualified }
      reached = keys.empty? ? nil : reached_from(keys)
      calls = reached ? @calls.select { |call| reached.include?(call.enclosing) } : @calls
      calls.group_by(&:bare_name).filter_map { |bare, list|
        next unless list.all? { |call| call.receiver.kind == "singleton" && call.receiver.const }

        [bare, list.map { |call| call.receiver.const }.uniq.sort]
      }.to_h
    end

    # The names an RSpec example starting on that line refers to: its own
    # block, the `let`, `subject`, and hook blocks of the groups around it,
    # the arguments of those groups, and the same-file helpers all of them
    # call. A group described as `"#total"` or `".build"` names that method.
    # Nil when no example starts on the line.
    #: (Integer line) -> Array[String]?
    def example_references(line)
      keys = example_keys(line)
      keys.empty? ? nil : names_reached_from(keys)
    end

    #: (Integer line) -> Array[String]
    def example_keys(line)
      example = @spec_blocks.find { |block| block.kind == "example" && block.start_line == line }
      return [] unless example

      groups = @spec_blocks.select { |block| block.kind == "group" && block.covers?(line) }
      setups = @spec_blocks.select { |block|
        next false unless block.kind == "setup"

        parent = @spec_blocks.select { |group| group.kind == "group" && group.covers?(block.start_line) }.max_by(&:start_line)
        parent.nil? || groups.include?(parent)
      }
      [example, *groups, *setups].map(&:key)
    end

    # The strings shaped like a file path (`"exe/tool"`, `"../bin/x"`) that
    # the test or example, or the same-file helpers it calls, writes: the
    # path of a script it may start in another process. With no such test
    # or example, those of the whole file.
    #: (String qualified, Integer? line) -> Array[String]
    def paths_named(qualified, line)
      keys = line ? example_keys(line) : [@methods.find { |method| method.qualified == qualified }&.qualified].compact
      return @paths.values.flatten.uniq.sort if keys.empty?

      reached_from(keys).flat_map { |name| @paths.fetch(name, []) }.uniq.sort
    end

    # Code outside the namespace cannot name a private constant, so no method
    # under it is an entry point, whatever its own visibility says. A revision
    # passes the names from all its files, since a namespace can be reopened.
    #: (Array[Method] methods, Array[String] names) -> Array[Method]
    def self.hide_private_constants(methods, names)
      methods.map do |method|
        hidden = names.any? { |name| method.qualifier == name || method.qualifier.start_with?("#{name}::") }
        hidden ? method.with(visibility: "private") : method
      end
    end

    private

    #: (Array[String] keys) -> Array[String]
    def names_reached_from(keys)
      reached = reached_from(keys)
      names = reached.flat_map { |name| @references.fetch(name, []) }
      (names + receiver_names(reached) + factory_names(reached)).uniq.sort
    end

    #: (Array[String] keys) -> Array[String]
    def reached_from(keys)
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
      reached
    end

    # `Index.parse` for a call whose receiver the source names as the class
    # `Index` or as an instance of it, so a reader can tell it from another
    # class's `parse`. A constructor is already listed as `Owner.new`.
    #: (Array[String?] enclosings) -> Array[String]
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

    # The private readers below take Prism nodes as untyped: they branch on
    # a node's class, on `respond_to?`, and on what Prism 0.19 and 1.x name
    # differently, which RBS types cannot follow without a rewrite.

    #: (untyped node, String qualifier, Symbol visibility, bool singleton) -> void
    def scan_body(node, qualifier, visibility, singleton)
      vis = visibility
      statements(node).each do |stmt|
        vis = scan_statement(stmt, qualifier, vis, singleton)
      end
    end

    #: (untyped node) -> Array[untyped]
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

    # The visibility the statements after this one get.
    #: (untyped stmt, String qualifier, Symbol visibility, bool singleton) -> Symbol
    def scan_statement(stmt, qualifier, visibility, singleton)
      case stmt
      when Prism::ClassNode, Prism::ModuleNode
        name = const_name(stmt.constant_path)
        nested = join_qual(qualifier, name)
        record_constant(@namespaces, nested, stmt.location.start_line, stmt.location.end_line, @lines[stmt.location.start_line - 1]) if name
        record_members(stmt.superclass, nested) if stmt.is_a?(Prism::ClassNode) && stmt.superclass.is_a?(Prism::CallNode)
        parent = stmt.is_a?(Prism::ClassNode) && name && const_name(stmt.superclass)
        @superclasses << Superclass.new(qualified: nested, written: parent, scope: qualifier.to_s) if parent
        scan_body(stmt, nested, :public, false)
        record_endpoints(stmt, nested, api_prefix(stmt)) if parent && API_SUPERCLASS.match?(parent)
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
        list = symbol_list(stmt.value)
        @symbol_lists[full] = list if list
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
        record_callbacks(stmt, qualifier) if (stmt.receiver.nil? || stmt.receiver.is_a?(Prism::SelfNode)) && !singleton && RECORD_CALLBACKS.key?(stmt.name)
        record_association(stmt, qualifier) if stmt.receiver.nil? && !singleton && ASSOCIATION_READERS.include?(stmt.name)
        if stmt.receiver.nil? && ATTRIBUTE_MACROS.key?(stmt.name)
          record_attributes_as_methods(stmt, qualifier, visibility == :module_function ? :public : visibility, singleton)
        end
        record_scope(stmt, qualifier) if scope?(stmt) && !singleton
        record_delegates(stmt, qualifier, singleton) if stmt.receiver.nil? && stmt.name == :delegate
        record_enum(stmt, qualifier) if stmt.receiver.nil? && stmt.name == :enum && !singleton
        visibility
      else
        visibility
      end
    end

    #: (Prism::CallNode node) -> bool
    def visibility_modifier?(node)
      node.receiver.nil? && VISIBILITY.include?(node.name)
    end

    #: (untyped stmt, String qualifier, Symbol visibility, bool singleton) -> Symbol
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
    #: (untyped stmt, String qualifier, Symbol visibility) -> Symbol
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

    #: (String qualifier, String bare) -> void
    def to_module_function(qualifier, bare)
      @methods.map! do |method|
        next method unless method.qualifier == qualifier.to_s && method.bare_name == bare && method.kind == "instance"

        @module_functions << method.qualified
        method.with(kind: "singleton", visibility: "public", qualified: self.class.qualify(qualifier, bare, true))
      end
    end

    #: (untyped stmt, String qualifier) -> void
    def record_private_constants(stmt, qualifier)
      (stmt.arguments&.arguments || []).each do |arg|
        @private_constants << join_qual(qualifier, arg.unescaped.to_s) if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      end
    end

    #: (untyped stmt, String qualifier) -> void
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

    #: (Prism::DefNode node, String qualifier, Symbol visibility, bool singleton_context, ?explicit: bool) -> void
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

    # The statements of an executable outside its `def`, class, and module
    # bodies, as one method: a change to its usage text or to the `case`
    # that picks a command is a change to it, and an edit inside a `def`
    # is not. Its source holds only those statements, so `changes` sees
    # an edit to them by the source alone.
    # The script's method name.
    #: (untyped program) -> String
    def record_script(program)
      top = statements(program).reject { |stmt| [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].any? { |kind| stmt.is_a?(kind) } }
      name = self.class.script_name(@file)
      return name if top.empty?

      @methods << self.class::Method.new(
        file: @file, bare_name: name, qualifier: "", qualified: name, kind: "script", visibility: "public",
        start_line: top.first.location.start_line, end_line: top.last.location.end_line,
        source: top.map { |stmt| extract_lines(stmt.location.start_line, stmt.location.end_line) }.join("\n"),
        params: "", macro: "script"
      )
      name
    end

    # A string, a lambda, or a block runs code the line does not name, so
    # only symbols count.
    #: (untyped stmt, String qualifier) -> void
    def record_callbacks(stmt, qualifier)
      arguments = Array(stmt.arguments&.arguments) #: Array[untyped]
      options = arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .select { |pair| pair.key.is_a?(Prism::SymbolNode) && CALLBACK_CONDITIONS.include?(pair.key.unescaped) }
      # @type var named: Array[[String, String]]
      named = stmt.name == :validates ? [] : arguments.grep(Prism::SymbolNode).map { |arg| [arg.unescaped, ":#{arg.unescaped}"] }
      named += options.flat_map do |pair|
        values = pair.value.is_a?(Prism::ArrayNode) ? pair.value.elements : [pair.value]
        values.grep(Prism::SymbolNode).map { |arg| [arg.unescaped, "#{pair.key.unescaped}: :#{arg.unescaped}"] }
      end
      context = arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .find { |pair| pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == "on" }&.value
      contexts = callback_contexts(context)
      on = contexts && CONTEXT_MACROS.include?(stmt.name) ? ", on: #{slice_of(context)}" : ""
      named.each do |method, written|
        @callbacks << Callback.new(qualifier: qualifier.to_s, macro: stmt.name.to_s, method: method, declared: "#{stmt.name} #{written}#{on}", contexts: contexts)
      end
    end

    # `belongs_to :cosigner, class_name: "Borrower"` reads a Borrower. A
    # polymorphic one reads whatever class the row names.
    #: (untyped stmt, String qualifier) -> void
    def record_association(stmt, qualifier)
      name, *rest = Array(stmt.arguments&.arguments) #: Array[untyped]
      return unless name.is_a?(Prism::SymbolNode)

      options = rest.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        .select { |pair| pair.key.is_a?(Prism::SymbolNode) }.to_h { |pair| [pair.key.unescaped, pair.value] }
      return if options.key?("polymorphic")

      written = options["class_name"]
      model = if written.nil? then self.class.model_name(name.unescaped)
      elsif written.is_a?(Prism::StringNode) then written.unescaped.delete_prefix("::")
      end
      @association_classes[self.class.qualify(qualifier, name.unescaped, false)] = model if model
    end

    # An `on:` the source does not spell as symbols could be any context,
    # so it narrows nothing.
    #: (untyped value) -> Array[String]?
    def callback_contexts(value)
      values = value.is_a?(Prism::ArrayNode) ? value.elements : [value]
      return nil if values.empty? || !values.all?(Prism::SymbolNode)

      values.map(&:unescaped)
    end

    #: (untyped stmt, String qualifier, Symbol visibility, bool singleton) -> void
    def record_attributes_as_methods(stmt, qualifier, visibility, singleton)
      suffixes = ATTRIBUTE_MACROS.fetch(stmt.name)
      member_symbols(stmt, qualifier).each do |arg|
        suffixes.each do |suffix|
          macro = suffix.empty? ? "attr_reader" : "attr_writer"
          record_generated(arg, qualifier, "#{arg.unescaped}#{suffix}", visibility, singleton, macro, "#{macro} :#{arg.unescaped}")
        end
      end
    end

    # `scope :recent, -> { ... }` and `scope(:old) { ... }` define the class
    # method `Post.recent`, and its body is the whole statement.
    #: (untyped stmt) -> bool
    def scope?(stmt)
      stmt.receiver.nil? && stmt.name == :scope && stmt.arguments&.arguments&.first.is_a?(Prism::SymbolNode) && !scope_body(stmt).nil?
    end

    #: (untyped stmt) -> (Prism::LambdaNode | Prism::BlockNode)?
    def scope_body(stmt)
      body = stmt.arguments.arguments[1]
      return body if body.is_a?(Prism::LambdaNode)

      stmt.block if stmt.block.is_a?(Prism::BlockNode)
    end

    #: (untyped stmt, String qualifier) -> void
    def record_scope(stmt, qualifier)
      bare = stmt.arguments.arguments.first.unescaped
      body = scope_body(stmt) #: Prism::LambdaNode | Prism::BlockNode
      params = body.parameters #: untyped
      params = params.parameters if params.is_a?(Prism::BlockParametersNode)
      @methods << self.class::Method.new(
        file: @file,
        bare_name: bare,
        qualifier: qualifier.to_s,
        qualified: self.class.qualify(qualifier, bare, true),
        kind: "singleton",
        visibility: "public",
        start_line: stmt.location.start_line,
        end_line: stmt.location.end_line,
        source: extract_lines(stmt.location.start_line, stmt.location.end_line),
        params: params&.location&.slice.to_s.gsub(/\s+/, ""),
        macro: "scope"
      )
    end

    # `prefix :api` puts its segment before every path of the class.
    #: (untyped body) -> Array[String]
    def api_prefix(body)
      call = statements(body).find { |stmt| stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :prefix }
      call ? [path_segment(call.arguments&.arguments&.first)].compact : []
    end

    # `described` is the line of a `desc` or `params` before the block that
    # holds these statements, which describes the first endpoint in it.
    # The line of a `desc` or `params` that no endpoint has taken yet.
    #: (untyped body, String qualifier, Array[String] path, ?Integer? described) -> Integer?
    def record_endpoints(body, qualifier, path, described = nil)
      statements(body).each do |stmt|
        # @type var call: untyped
        # @type var segment: untyped
        call = stmt if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?
        if call && ENDPOINT_DESCRIPTIONS.include?(call.name)
          described ||= call.location.start_line
          next
        end
        block = call&.block.is_a?(Prism::BlockNode)
        segment = path_segment(call.arguments&.arguments&.first) if block
        if block && PATH_BLOCKS.include?(call.name)
          described = record_endpoints(call.block, qualifier, [*path, *(call.name == :route_param && segment ? ":#{segment}" : segment)], described)
          next
        elsif block && ENDPOINT_VERBS.include?(call.name)
          record_endpoint(call, qualifier, [*path, *segment], described || call.location.start_line)
        end
        described = nil
      end
      described
    end

    #: (Prism::CallNode stmt, String qualifier, Array[String] path, Integer start_line) -> void
    def record_endpoint(stmt, qualifier, path, start_line)
      bare = "#{stmt.name.upcase} /#{path.join("/")}"
      qualified = self.class.qualify(qualifier, bare, false)
      @endpoints[stmt.location.start_offset] = qualified
      @methods << self.class::Method.new(
        file: @file, bare_name: bare, qualifier: qualifier.to_s, qualified: qualified, kind: "endpoint", visibility: "public",
        start_line: start_line, end_line: stmt.location.end_line, source: extract_lines(start_line, stmt.location.end_line), params: "", macro: nil
      )
    end

    # A path argument's segments with no slash at either end, or nil for
    # none. A part the source computes is kept as its source in braces, so
    # the endpoint's name says that its path is not known.
    #: (untyped node) -> String?
    def path_segment(node)
      return nil if node.nil? || node.is_a?(Prism::KeywordHashNode)

      text = path_parts(node).map { |part| part.is_a?(String) ? part : "{#{part.location.slice}}" }.join
      trimmed = text.gsub(%r{\A/+|/+\z}, "")
      trimmed.empty? ? nil : trimmed
    end

    # The parts of a path the source writes: the text of each literal part,
    # and the node of each part it computes. A constant the file assigns a
    # string or a symbol is literal.
    #: (untyped node) -> Array[String | Prism::Node]
    def path_parts(node)
      case node
      when Prism::StringNode, Prism::SymbolNode
        [node.unescaped]
      when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode
        node.parts.flat_map do |part|
          # @type var inner: untyped
          inner = part.statements&.body if part.is_a?(Prism::EmbeddedStatementsNode)
          if part.is_a?(Prism::StringNode) then [part.unescaped]
          elsif inner&.size == 1 then path_parts(inner.first)
          else [part]
          end
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        value = @string_constants[name_of(node).to_s]
        value ? [value] : [node]
      else
        [node]
      end
    end

    # The string and symbol constants the file assigns, by name. A name
    # assigned two values is left out, since the scope that reads it is not
    # followed.
    #: (Prism::Node root) -> Hash[String, String]
    def string_constants(root)
      values = Hash.new { |hash, key| hash[key] = [] } #: Hash[String, Array[String]]
      nodes = [root] #: Array[Prism::Node]
      until nodes.empty?
        node = nodes.pop #: Prism::Node
        if node.is_a?(Prism::ConstantWriteNode) && (node.value.is_a?(Prism::StringNode) || node.value.is_a?(Prism::SymbolNode))
          values[node.name.to_s] |= [node.value.unescaped]
        end
        nodes.concat(node.compact_child_nodes)
      end
      values.filter_map { |name, found| [name, found.first] if found.one? }.to_h
    end

    # A request a test sends, as `post "/things/#{thing.id}/refresh"`, by
    # verb and path, with no query string and a `*` for each segment the
    # test computes; or by verb and path helper, as `post things_path` is.
    #: (Prism::CallNode node) -> String?
    def request_name(node)
      return nil unless node.receiver.nil? && ENDPOINT_VERBS.include?(node.name)

      path = node.arguments&.arguments&.first
      verb = node.name.upcase
      if path.is_a?(Prism::CallNode) && path.receiver.nil? && path.name.to_s.match?(ROUTE_HELPER)
        return "#{verb} #{path.name.to_s.sub(/_url\z/, "_path")}"
      end
      return nil unless path.is_a?(Prism::StringNode) || path.is_a?(Prism::InterpolatedStringNode)

      text = path_parts(path).map { |part| part.is_a?(String) ? part : COMPUTED_SEGMENT }.join.sub(/[?#].*/m, "")
      return nil unless text.start_with?("/", COMPUTED_SEGMENT)

      segments = text.split("/").map { |segment| segment.include?(COMPUTED_SEGMENT) ? COMPUTED_SEGMENT : segment }
      return nil if segments.reject(&:empty?).all?(COMPUTED_SEGMENT)

      "#{verb} #{segments.join("/")}"
    end

    # `delegate :name, to: :author, prefix: true` defines `author_name`, and
    # a change to the options changes every name the line delegates.
    #: (untyped stmt, String qualifier, bool singleton) -> void
    def record_delegates(stmt, qualifier, singleton)
      names = Array(stmt.arguments&.arguments).grep(Prism::SymbolNode) #: Array[untyped]
      options = Array(stmt.arguments&.arguments).grep(Prism::KeywordHashNode).first #: untyped
      return if names.empty? || options.nil?

      pairs = options.elements.grep(Prism::AssocNode).select { |pair| pair.key.is_a?(Prism::SymbolNode) }.to_h { |pair| [pair.key.unescaped, pair.value] }
      return unless pairs.key?("to")

      prefix = case (value = pairs["prefix"])
      when Prism::TrueNode then pairs["to"].is_a?(Prism::SymbolNode) ? "#{pairs["to"].unescaped}_" : ""
      when Prism::SymbolNode, Prism::StringNode then "#{value.unescaped}_"
      else ""
      end
      visibility = pairs["private"].is_a?(Prism::TrueNode) ? :private : :public
      names.each do |arg|
        record_generated(arg, qualifier, "#{prefix}#{arg.unescaped}", visibility, singleton, "delegate", "delegate :#{arg.unescaped}, #{slice_of(options)}")
      end
    end

    ENUM_OPTIONS = %w[prefix suffix scopes default instance_methods validate].freeze #: Array[String]

    # `enum :status, { draft: 0, live: 1 }` defines `draft?`, `draft!`, and
    # the scopes `Post.draft` and `Post.not_draft` for each value. Each value
    # keeps its own line, so changing one value changes that value's methods.
    # Rails 8 removed the `enum status: {...}` form, so it is not read.
    #: (untyped stmt, String qualifier) -> void
    def record_enum(stmt, qualifier)
      name, *rest = Array(stmt.arguments&.arguments) #: Array[untyped]
      return unless name.is_a?(Prism::SymbolNode)

      # @type var listed: untyped
      pairs = rest.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode).select { |pair| pair.key.is_a?(Prism::SymbolNode) }
      options = pairs.select { |pair| ENUM_OPTIONS.include?(pair.key.unescaped) }
      listed = rest.find { |arg| arg.is_a?(Prism::HashNode) || arg.is_a?(Prism::ArrayNode) }
      values = case listed
      when Prism::HashNode
        entries = listed.elements.grep(Prism::AssocNode) #: Array[untyped]
        entries.select { |pair| pair.key.is_a?(Prism::SymbolNode) }.map { |pair| [pair.key.unescaped, pair] }
      when Prism::ArrayNode
        symbols = listed.elements.grep(Prism::SymbolNode) #: Array[untyped]
        symbols.map { |value| [value.unescaped, value] }
      else (pairs - options).map { |pair| [pair.key.unescaped, pair] }
      end
      option = options.to_h { |pair| [pair.key.unescaped, pair.value] }
      affix = lambda do |key, joined|
        case (value = option[key])
        when Prism::TrueNode then joined.call(name.unescaped)
        when Prism::SymbolNode, Prism::StringNode then joined.call(value.unescaped)
        else ""
        end
      end
      prefix = affix.call("prefix", ->(text) { "#{text}_" })
      suffix = affix.call("suffix", ->(text) { "_#{text}" })
      written = options.map { |pair| ", #{slice_of(pair)}" }.join
      values.each do |value, node|
        method = "#{prefix}#{value}#{suffix}"
        source = "enum :#{name.unescaped}, #{node.is_a?(Prism::SymbolNode) ? ":#{value}" : slice_of(node)}#{written}"
        unless option["instance_methods"].is_a?(Prism::FalseNode)
          ["#{method}?", "#{method}!"].each { |bare| record_generated(node, qualifier, bare, :public, false, "enum", source) }
        end
        unless option["scopes"].is_a?(Prism::FalseNode)
          [method, "not_#{method}"].each { |bare| record_generated(node, qualifier, bare, :public, true, "enum", source) }
        end
      end
    end

    #: (untyped call, String qualifier) -> void
    def record_members(call, qualifier)
      builder = const_name(call.receiver)
      writers = MEMBER_BUILDERS[[builder&.to_sym, call.name]]
      return if writers.nil?

      macro = "#{builder}.#{call.name}"
      member_symbols(call, qualifier).each do |arg|
        source = "#{macro}(:#{arg.unescaped})"
        record_generated(arg, qualifier, arg.unescaped, :public, false, macro, source)
        record_generated(arg, qualifier, "#{arg.unescaped}=", :public, false, macro, source) if writers
      end
    end

    # The symbols a member list names, with `*FIELDS` read from a constant
    # this file set to a list of symbols before it, looked up from the
    # innermost namespace out. Each member keeps the line of its own symbol,
    # so a change to the list is a change to that member.
    #: (untyped call, String qualifier) -> Array[Prism::SymbolNode]
    def member_symbols(call, qualifier)
      Array(call.arguments&.arguments).flat_map do |arg|
        case arg
        when Prism::SymbolNode
          [arg]
        when Prism::SplatNode
          name = const_name(arg.expression)
          parts = qualifier.to_s.split("::")
          found = name && parts.size.downto(0).map { |n| [*parts.first(n), name].join("::") }.find { |full| @symbol_lists.key?(full) }
          found ? @symbol_lists.fetch(found) : []
        else
          []
        end
      end
    end

    # `[:a, :b]`, `%i[a b]`, and either with `.freeze`.
    #: (untyped node) -> Array[Prism::SymbolNode]?
    def symbol_list(node)
      node = node.receiver if node.is_a?(Prism::CallNode) && node.name == :freeze && node.arguments.nil?
      return nil unless node.is_a?(Prism::ArrayNode) && node.elements.all?(Prism::SymbolNode)

      node.elements #: Array[Prism::SymbolNode]
    end

    #: (Prism::Node arg, String qualifier, String bare, Symbol visibility, bool singleton, String macro, String source) -> void
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

    #: (String qualifier, String bare, Symbol visibility, bool singleton) -> void
    def mark_visibility(qualifier, bare, visibility, singleton)
      kind = singleton ? "singleton" : "instance"
      @new_visibility[qualifier.to_s] = visibility.to_s if singleton && bare == "new"
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
    #: (Array[Constant] list, String full, Integer start_line, Integer end_line, String source) -> void
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
    #: () -> void
    def type_instance_variables
      @calls.map! do |call|
        next call unless call.receiver.kind == "ivar"

        qualifier, _sep, _bare = self.class.split_qualified(call.enclosing.to_s)
        named = @ivar_classes[[qualifier, call.receiver.const]].uniq
        call.with(receiver: typed_or_named(named, named.size == 1, call.receiver.const.delete_prefix("@")))
      end
    end

    # A local read starts `named`; most are parameters and stay so. This
    # runs before the instance variables become `named` too.
    #: () -> void
    def type_local_variables
      @calls.map! do |call|
        next call unless call.receiver.kind == "named"

        procs = @local_procs.fetch([call.enclosing, call.receiver.const], [])
        next call.with(receiver: PROC_RECEIVER) if procs.any? && procs.all?

        assigned = @local_classes.fetch([call.enclosing, call.receiver.const], [])
        next call if assigned.all?(&:empty?)

        built = assigned.flatten.uniq
        call.with(receiver: typed_or_named(built, assigned.all? { |consts| consts.size == 1 }, call.receiver.const))
      end
    end

    #: (Array[String] built, bool every_assignment_builds, String name) -> Receiver
    def typed_or_named(built, every_assignment_builds, name)
      if built.empty?
        Receiver.new(kind: "named", const: name)
      elsif built.size == 1 && every_assignment_builds
        Receiver.new(kind: "instance", const: built.first)
      else
        UNKNOWN_RECEIVER
      end
    end

    # `let(:cart) { Cart.new }` makes `cart.total` a call on a Cart, as a
    # local variable would. A name defined twice, in two groups, types none.
    #: () -> void
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
    #: () -> void
    def type_returned_receivers
      @calls.map! do |call|
        next call unless call.receiver.kind == "returned"

        qualifier, sep, _bare = self.class.split_qualified(call.enclosing.to_s)
        names = [sep == ".", sep != "."].map { |singleton| self.class.qualify(qualifier, call.receiver.const, singleton) }
        consts = @returned.values_at(*names).compact.first.to_a.uniq
        reader = names.first
        # A singleton reader names `Loan.borrower`, which no association line records.
        association = @association_classes[reader] unless @defined.fetch(call.receiver.const, []).include?(reader)
        next call.with(receiver: Receiver.new(kind: "instance", const: association)) if association

        call.with(receiver: consts.empty? ? UNKNOWN_RECEIVER : Receiver.new(kind: "one_of", const: consts))
      end
    end

    # The constants a method body can return, or nil when it can return
    # anything else. A `nil` branch adds none.
    #: (untyped node) -> Array[String]?
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

    #: (untyped node) -> bool
    def returns?(node)
      return false if node.nil? || node.is_a?(Prism::DefNode)

      node.is_a?(Prism::ReturnNode) || node.compact_child_nodes.any? { |child| returns?(child) }
    end

    # The constants a value builds with `Const.new`, through `a || b`,
    # `c ? a : b`, and parentheses.
    # `-> {}`, `lambda {}`, `proc {}`, and `Proc.new {}` make a Proc.
    #: (untyped node) -> bool
    def proc_literal?(node)
      return true if node.is_a?(Prism::LambdaNode)
      return false unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

      if node.receiver.nil?
        %i[lambda proc].include?(node.name)
      else
        node.name == :new && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Proc
      end
    end

    #: (untyped node) -> Array[String]
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

    #: () -> void
    def rename_module_function_callers
      renamed = @module_functions.to_h { |name| [name, name.sub(/#(?=[^#]*\z)/, ".")] }
      @calls.map! { |call| renamed.key?(call.enclosing) ? call.with(enclosing: renamed[call.enclosing]) : call }
      renamed.each { |from, to| @references[to] = @references.delete(from).to_a if @references.key?(from) }
    end

    #: (untyped node, String qualifier) -> String
    def constant_target(node, qualifier)
      node.is_a?(Prism::ConstantWriteNode) ? join_qual(qualifier, node.name.to_s) : const_name(node.target).to_s
    end

    # `Point = Struct.new(:x) do ... end` and `Class.new do ... end` define
    # methods for that constant. Those methods are indexed on their own, so
    # the constant keeps only the text up to the block's `do` or `{`, which
    # still shows a block that came or went.
    #: (untyped node) -> Prism::BlockNode?
    def value_block(node)
      value = node.value
      value.block if value.is_a?(Prism::CallNode) && value.block.is_a?(Prism::BlockNode)
    end

    # The constant's source up to its block, and the line that ends.
    #: (untyped node) -> [String, Integer]
    def constant_header(node)
      block = value_block(node)
      return [slice_of(node), node.location.end_line] unless block

      length = block.opening_loc.end_offset - node.location.start_offset
      header = @source.byteslice(node.location.start_offset, length) #: String
      [header.force_encoding(@source.encoding).rstrip, block.location.start_line]
    end

    #: (untyped node, String qualifier, bool singleton_context, String? enclosing) -> void
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

        endpoint = @endpoints[node.location.start_offset]
        return walk(node.block, qualifier, singleton_context, endpoint) if endpoint

        if enclosing.nil? && !singleton_context && scope?(node)
          scope_name = node.arguments&.arguments&.first #: Prism::SymbolNode
          scope = self.class.qualify(qualifier, scope_name.unescaped, true)
          return walk(scope_body(node), qualifier, true, scope)
        end

        if node.name
          @calls << self.class::Call.new(
            file: @file,
            bare_name: node.name.to_s,
            line: node.location.start_line,
            enclosing: enclosing,
            receiver: receiver_of(node.receiver)
          )
          # `lines.sum(&:total_cents)` sends total_cents to each element,
          # whose class the source does not name.
          if node.block.is_a?(Prism::BlockArgumentNode) && node.block.expression.is_a?(Prism::SymbolNode)
            @calls << self.class::Call.new(file: @file, bare_name: node.block.expression.unescaped, line: node.location.start_line,
              enclosing: enclosing, receiver: UNKNOWN_RECEIVER)
          end
          sent = sent_name(node)
          if sent
            @calls << self.class::Call.new(file: @file, bare_name: sent, line: node.location.start_line,
              enclosing: enclosing, receiver: receiver_of(node.receiver))
          end
          refer(enclosing, node.name) unless spec_helper_call?(node)
          owner = constructor_owner(node) || described_owner(node)
          refer(enclosing, "#{owner}.new") if owner
          named = reflective_name(node)
          refer(enclosing, named) if named
          refer(enclosing, "to_s") if MESSAGE_CALLS.include?(node.name)
          request = request_name(node)
          refer(enclosing, request) if request
          factory = factory_built(node)
          @factory_calls[enclosing] << [node.name.to_s, factory, factory_traits(node)] if factory
          mark_compared_strings(node)
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
      when Prism::StringNode
        text = node.unescaped
        @paths[enclosing] << text if text.valid_encoding? && text.match?(PATH_LIKE) && !@compared.key?(node.location.start_offset)
      when Prism::LocalVariableWriteNode
        @local_classes[[enclosing, node.name.to_s]] << built_constants(node.value).uniq
        @local_procs[[enclosing, node.name.to_s]] << proc_literal?(node.value)
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when *LOCAL_BINDINGS
        @local_classes[[enclosing, node.name.to_s]] << [] if node.name
        # `&block` binds the block given, which is a Proc.
        @local_procs[[enclosing, node.name.to_s]] << node.is_a?(Prism::BlockParameterNode) if node.name
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode
        @ivar_classes[[qualifier.to_s, node.name.to_s]].concat(built_constants(node.value))
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      else
        node.compact_child_nodes.each { |child| walk(child, qualifier, singleton_context, enclosing) }
      end
    end

    # A string an assertion or a matcher compares with a value, as in
    # `assert_includes error.backtrace.first, "lib/tool/model.rb"`, is
    # text the test expects, not the path of a script it starts. Only a
    # direct argument counts, so `assert_equal "1\n", IO.popen(["ruby",
    # "exe/tool"], &:read)` still names `exe/tool`.
    #: (untyped node) -> void
    def mark_compared_strings(node)
      return unless COMPARING_CALL.match?(node.name.to_s) && node.arguments

      node.arguments.arguments.grep(Prism::StringNode).each { |arg| @compared[arg.location.start_offset] = true }
    end

    #: (untyped node) -> bool
    def spec_block?(node)
      return false unless node.block.is_a?(Prism::BlockNode) && SPEC_KINDS.key?(node.name)

      node.receiver.nil? || (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :RSpec)
    end

    #: (untyped node, String qualifier, bool singleton_context, String? enclosing) -> void
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
    #: (untyped node) -> Array[String]
    def spec_helper_names(node)
      # @type var own: Array[String]
      # @type var named: untyped
      named = node.arguments&.arguments&.first if node.is_a?(Prism::CallNode)
      own = node.is_a?(Prism::CallNode) && spec_helper_name?(node, named) ? [named.unescaped] : []
      own << "subject" if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block && %i[subject subject!].include?(node.name)
      own + node.compact_child_nodes.flat_map { |child| spec_helper_names(child) }
    end

    # An unnamed `subject` is called as `subject`, and a named one answers
    # to both names.
    #: (untyped node) -> void
    def record_spec_helper(node)
      first = node.arguments&.arguments&.first
      names = first.is_a?(Prism::SymbolNode) ? [first.unescaped] : [] #: Array[String]
      names << "subject" if node.name.start_with?("subject")
      built = built_constants(node.block.body).uniq
      names.each { |name| @helper_classes[name] << (built.size == 1 ? built.first : nil) }
    end

    #: (untyped node, untyped arg) -> bool
    def spec_helper_name?(node, arg)
      SPEC_HELPERS.include?(node.name) && node.receiver.nil? && arg.is_a?(Prism::SymbolNode) && node.arguments.arguments.first.equal?(arg)
    end

    #: (untyped node) -> bool
    def spec_helper_call?(node)
      node.receiver.nil? && node.arguments.nil? && @spec_helpers.include?(node.name.to_s)
    end

    # `described_class.new` builds the constant the enclosing group describes.
    #: (untyped node) -> String?
    def described_owner(node)
      return nil unless node.name == :new && node.receiver.is_a?(Prism::CallNode)
      return nil unless node.receiver.name == :described_class && node.receiver.receiver.nil?

      @described.last
    end

    # A file that defines a method of the call's name calls its own
    # helper, not FactoryBot's.
    #: (Array[String?] enclosings) -> Array[String]
    def factory_names(enclosings)
      enclosings.flat_map { |name| @factory_calls.fetch(name, []) }
        .flat_map { |call, factory, traits|
          @defined.key?(call) ? [] : [nil, *traits].map { |trait| self.class.factory_mention(factory, call, trait) }
        }
    end

    # `create(:loan, :cosigned)` names the trait :cosigned after the factory.
    #: (untyped node) -> Array[String]
    def factory_traits(node)
      traits = Array(node.arguments&.arguments).drop(1).grep(Prism::SymbolNode) #: Array[untyped]
      traits.map(&:unescaped)
    end

    # `create(:loan)` or `FactoryBot.build("loan")` builds from the factory
    # `loan`. A name a run computes cannot be read.
    #: (untyped node) -> String?
    def factory_built(node)
      return nil unless FACTORY_CALLS.include?(node.name)
      return nil unless node.receiver.nil? || (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :FactoryBot)

      first = node.arguments&.arguments&.first
      first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
    end

    #: (String? enclosing, String | Symbol name) -> void
    def refer(enclosing, name)
      @references[enclosing] << name.to_s
    end


    # `emitter.send(:write)` calls `write` on the receiver of `send`.
    #: (untyped node) -> String?
    def sent_name(node)
      return nil unless SEND_CALLS.include?(node.name)

      first = node.arguments&.arguments&.first
      first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
    end

    #: (untyped node) -> String?
    def reflective_name(node)
      return nil unless REFLECTIVE_CALLS.include?(node.name)

      first = node.arguments&.arguments&.first
      first.unescaped if first.is_a?(Prism::StringNode)
    end

    #: (untyped node) -> Receiver
    def receiver_of(node)
      case node
      when nil, Prism::SelfNode
        Receiver.new(kind: "self", const: nil)
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Receiver.new(kind: "singleton", const: const_name(node))
      when Prism::InstanceVariableReadNode
        Receiver.new(kind: "ivar", const: node.name.to_s)
      when Prism::LocalVariableReadNode
        Receiver.new(kind: "named", const: node.name.to_s)
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

    #: (untyped node) -> String?
    def constructor_owner(node)
      return nil unless node.name == :new

      receiver = node.receiver
      const_name(receiver) if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
    end

    # Prism 0.19, the default on Ruby 3.3, has no ConstantPathNode#name: the
    # last segment is a ConstantReadNode in `child`, which Prism 1.x deprecates.
    # `full_name` and the source text after `::` are not the same on both.
    #: (untyped node) -> Symbol
    def name_of(node)
      node.respond_to?(:name) ? node.name : node.child.name
    end

    #: (untyped node) -> String?
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

    #: (String? qualifier, String? name) -> String
    def join_qual(qualifier, name)
      return qualifier.to_s if name.nil? || name.empty?
      return name if qualifier.to_s.empty?

      "#{qualifier}::#{name}"
    end

    #: (Integer start_line, Integer end_line) -> String
    def extract_lines(start_line, end_line)
      lines = @lines[(start_line - 1)...end_line] #: Array[String]
      lines.map(&:rstrip).join("\n")
    end

    #: (Prism::Node node) -> String
    def slice_of(node)
      node.location.slice.to_s
    end
  end
end
