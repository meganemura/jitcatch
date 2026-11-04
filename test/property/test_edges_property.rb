# frozen_string_literal: true

require_relative "property_helper"

class TestEdgesProperty < Minitest::Test
  NAMES = %w[m0 m1 m2].freeze

  # `K.new` also reaches K#initialize when K defines one. A value the
  # source does not type goes to the class its name names: `value` to Value.
  def test_a_call_edge_goes_only_to_the_class_its_receiver_names
    Hegel.test do |tc|
      defined = [*(0..2).map { |k| "K#{k}" }, *%w[Value Kept Built]].to_h { |klass| [klass, tc.draw(arrays(sampled_from([*NAMES.flat_map { |name| [name, "self.#{name}"] }, "initialize"]), unique: true, max_size: 4))] }
      calls = tc.draw(arrays(composite { |inner|
        [inner.draw(sampled_from(%w[instance singleton param ivar kept local passed new])), "K#{inner.draw(integers(min_value: 0, max_value: 2))}", inner.draw(sampled_from(NAMES))]
      }, min_size: 1, max_size: 6))
      classes = defined.map { |klass, defs| "class #{klass}\n#{defs.map { |name| "  def #{name}\n    1\n  end\n" }.join}end\n" }
      bodies = calls.map do |shape, klass, name|
        { "instance" => "#{klass}.new.#{name}", "singleton" => "#{klass}.#{name}", "param" => "value.#{name}", "ivar" => "@held.#{name}", "kept" => "@kept.#{name}", "local" => "built = #{klass}.new\n    built.#{name}", "passed" => "built = value\n    built.#{name}", "new" => "#{klass}.new" }.fetch(shape)
      end
      caller_src = "class Caller\n  def initialize(kept)\n    @held = K0.new\n    @kept = kept\n  end\n\n#{bodies.each_with_index.map { |body, i| "  def c#{i}(value)\n    #{body}\n  end\n" }.join("\n")}end\n"
      index = JitCatch::SourceIndex.parse(classes.join("\n") + caller_src, file: "lib/x.rb")
      edges = JitCatch::Changes.allocate.send(:edges_for, { "methods" => index.methods, "calls" => index.calls, "namespaces" => index.namespaces, "superclasses" => index.superclasses })
        .select { |edge| edge["from"].start_with?("Caller#c") }

      expected = calls.each_with_index.flat_map do |(shape, klass, name), i|
        owner, sep, defs_name = { "instance" => [klass, "#", name], "singleton" => [klass, ".", "self.#{name}"], "ivar" => ["K0", "#", name], "local" => [klass, "#", name], "param" => ["Value", "#", name], "kept" => ["Kept", "#", name], "passed" => ["Built", "#", name] }[shape]
        sent = owner && defined.fetch(owner).include?(defs_name) ? [["Caller#c#{i}", "#{owner}#{sep}#{name}"]] : []
        built = %w[instance local new].include?(shape) && defined.fetch(klass).include?("initialize") ? [["Caller#c#{i}", "#{klass}#initialize"]] : []
        sent + built
      end
      assert_equal expected.sort, edges.map { |edge| [edge["from"], edge["to"]] }.sort
    end
  end

  # A call on what a same-class method returns goes to each constant that
  # method can return and that defines the name, and nowhere when one of
  # the values it returns is not a constant or nil.
  def test_a_call_on_a_returned_constant_goes_to_each_constant_returned
    Hegel.test do |tc|
      defined = (0..2).to_h { |k| ["K#{k}", tc.draw(arrays(sampled_from(NAMES.map { |name| "self.#{name}" }), unique: true, max_size: 3))] }
      returned = tc.draw(arrays(sampled_from(%w[K0 K1 K2 nil value]), min_size: 1, max_size: 3))
      name = tc.draw(sampled_from(NAMES))
      body = case tc.draw(sampled_from(%w[case ternary last]))
      when "case" then "case value\n#{returned.each_with_index.map { |item, i| "    when #{i} then #{item}\n" }.join}    end"
      when "ternary" then returned.drop(1).reverse.reduce(returned.first) { |rest, item| "(value ? #{item} : #{rest})" }
      else returned.last
      end
      returned = [returned.last] if body == returned.last
      classes = defined.map { |klass, defs| "class #{klass}\n#{defs.map { |item| "  def #{item}\n    1\n  end\n" }.join}end\n" }
      caller_src = "class Caller\n  def call(value)\n    pick(value).#{name}\n  end\n\n  def pick(value)\n    #{body}\n  end\nend\n"
      index = JitCatch::SourceIndex.parse(classes.join("\n") + caller_src, file: "lib/x.rb")
      edges = JitCatch::Changes.allocate.send(:edges_for, { "methods" => index.methods, "calls" => index.calls, "namespaces" => index.namespaces, "superclasses" => index.superclasses })
        .select { |edge| edge["from"] == "Caller#call" && edge["to"].start_with?("K") }

      constants = returned.include?("value") ? [] : returned.grep(/\AK/).uniq
      expected = constants.select { |klass| defined.fetch(klass).include?("self.#{name}") }.map { |klass| "#{klass}.#{name}" }
      assert_equal expected.sort, edges.map { |edge| edge["to"] }.sort, caller_src
    end
  end
end
