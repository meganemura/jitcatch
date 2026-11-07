# frozen_string_literal: true

require "prism"

module JitCatch
  # The English inflections Active Support starts from, and the literal
  # `irregular`, `uncountable`, `singular`, `plural`, and `acronym` calls of
  # an app's `config/initializers/inflections.rb`, read as source, so a
  # route's helper and controller take the names Rails gives them
  # (`resources :people` draws `person_path`, `inflect.acronym "API"` makes
  # `APIKeysController`). A rule built at run time is not read.
  class Inflections
    def self.read(source)
      inflections = rails
      result = source ? Prism.parse(source) : nil
      inflections.apply_calls(result.value) if result&.success?
      inflections
    end

    # Active Support's own list, applied as an app's file would be, in the
    # same order, so a later rule takes precedence as it does there.
    def self.rails
      inflections = new
      [
        [/$/, "s"], [/s$/i, "s"], [/^(ax|test)is$/i, '\1es'], [/(octop|vir)us$/i, '\1i'], [/(octop|vir)i$/i, '\1i'],
        [/(alias|status)$/i, '\1es'], [/(bu)s$/i, '\1ses'], [/(buffal|tomat)o$/i, '\1oes'], [/([ti])um$/i, '\1a'],
        [/([ti])a$/i, '\1a'], [/sis$/i, "ses"], [/(?:([^f])fe|([lr])f)$/i, '\1\2ves'], [/(hive)$/i, '\1s'],
        [/([^aeiouy]|qu)y$/i, '\1ies'], [/(x|ch|ss|sh)$/i, '\1es'], [/(matr|vert|ind)(?:ix|ex)$/i, '\1ices'],
        [/^(m|l)ouse$/i, '\1ice'], [/^(m|l)ice$/i, '\1ice'], [/^(ox)$/i, '\1en'], [/^(oxen)$/i, '\1'], [/(quiz)$/i, '\1zes']
      ].each { |rule, replacement| inflections.plural(rule, replacement) }
      [
        [/s$/i, ""], [/(ss)$/i, '\1'], [/(n)ews$/i, '\1ews'], [/([ti])a$/i, '\1um'],
        [/((a)naly|(b)a|(d)iagno|(p)arenthe|(p)rogno|(s)ynop|(t)he)(sis|ses)$/i, '\1sis'], [/(^analy)(sis|ses)$/i, '\1sis'],
        [/([^f])ves$/i, '\1fe'], [/(hive)s$/i, '\1'], [/(tive)s$/i, '\1'], [/([lr])ves$/i, '\1f'], [/([^aeiouy]|qu)ies$/i, '\1y'],
        [/(s)eries$/i, '\1eries'], [/(m)ovies$/i, '\1ovie'], [/(x|ch|ss|sh)es$/i, '\1'], [/^(m|l)ice$/i, '\1ouse'],
        [/(bus)(es)?$/i, '\1'], [/(o)es$/i, '\1'], [/(shoe)s$/i, '\1'], [/(cris|test)(is|es)$/i, '\1is'], [/^(a)x[ie]s$/i, '\1xis'],
        [/(octop|vir)(us|i)$/i, '\1us'], [/(alias|status)(es)?$/i, '\1'], [/^(ox)en/i, '\1'], [/(vert|ind)ices$/i, '\1ex'],
        [/(matr)ices$/i, '\1ix'], [/(quiz)zes$/i, '\1'], [/(database)s$/i, '\1']
      ].each { |rule, replacement| inflections.singular(rule, replacement) }
      %w[person people man men child children sex sexes move moves zombie zombies].each_slice(2) { |one, many| inflections.irregular(one, many) }
      inflections.uncountable(*%w[equipment information rice money species series fish sheep jeans police])
      inflections
    end

    def initialize
      @plurals = []
      @singulars = []
      @uncountables = []
      @acronyms = {}
    end

    def pluralize(word) = apply(word, @plurals)

    def singularize(word) = apply(word, @singulars)

    # `api_keys` is `APIKeys` once `API` is an acronym.
    def camelize(word)
      word.split("_").map { |part| @acronyms[part] || part.capitalize }.join
    end

    # The other way: `APIKeysController` is `api_keys_controller`, as Active
    # Support's `underscore` splits a run of capitals before its last one.
    def underscore(camel)
      camel.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def plural(rule, replacement)
      @uncountables.delete(rule) if rule.is_a?(String)
      @uncountables.delete(replacement)
      @plurals.unshift([rule, replacement])
    end

    def singular(rule, replacement)
      @uncountables.delete(rule) if rule.is_a?(String)
      @uncountables.delete(replacement)
      @singulars.unshift([rule, replacement])
    end

    def irregular(one, many)
      @uncountables.delete(one)
      @uncountables.delete(many)
      first, rest = one[0], one[1..]
      many_first, many_rest = many[0], many[1..]
      if first.upcase == many_first.upcase
        plural(/(#{first})#{rest}$/i, "\\1#{many_rest}")
        plural(/(#{many_first})#{many_rest}$/i, "\\1#{many_rest}")
        singular(/(#{first})#{rest}$/i, "\\1#{rest}")
        singular(/(#{many_first})#{many_rest}$/i, "\\1#{rest}")
      else
        plural(/#{first.upcase}(?i)#{rest}$/, many_first.upcase + many_rest)
        plural(/#{first.downcase}(?i)#{rest}$/, many_first.downcase + many_rest)
        plural(/#{many_first.upcase}(?i)#{many_rest}$/, many_first.upcase + many_rest)
        plural(/#{many_first.downcase}(?i)#{many_rest}$/, many_first.downcase + many_rest)
        singular(/#{first.upcase}(?i)#{rest}$/, first.upcase + rest)
        singular(/#{first.downcase}(?i)#{rest}$/, first.downcase + rest)
        singular(/#{many_first.upcase}(?i)#{many_rest}$/, first.upcase + rest)
        singular(/#{many_first.downcase}(?i)#{many_rest}$/, first.downcase + rest)
      end
    end

    def uncountable(*words)
      @uncountables.concat(words.flatten)
    end

    def acronym(word)
      @acronyms[word.downcase] = word
    end

    # Each call in the file whose arguments are all literals, in order.
    def apply_calls(node)
      node.compact_child_nodes.each { |child| apply_calls(child) }
      return unless node.is_a?(Prism::CallNode) && READ.include?(node.name) && node.receiver

      args = Array(node.arguments&.arguments).map { |arg| literal(arg) }
      public_send(node.name, *args) unless args.empty? || args.include?(UNREAD)
    end

    READ = %i[plural singular irregular uncountable acronym].freeze
    UNREAD = Object.new.freeze

    private

    def apply(word, rules)
      return word if word.empty? || @uncountables.any? { |uncountable| word.match?(/\b#{Regexp.escape(uncountable)}\Z/i) }

      result = word.dup
      rules.each { |rule, replacement| break if result.sub!(rule, replacement) }
      result
    end

    def literal(node)
      case node
      when Prism::StringNode, Prism::SymbolNode then node.unescaped
      when Prism::RegularExpressionNode then Regexp.new(node.unescaped, node.options)
      when Prism::ArrayNode
        items = node.elements.map { |element| literal(element) }
        items.include?(UNREAD) ? UNREAD : items
      else UNREAD
      end
    end
  end
end
