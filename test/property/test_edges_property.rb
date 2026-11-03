# frozen_string_literal: true

require_relative "property_helper"

class TestEdgesProperty < Minitest::Test
  NAMES = %w[m0 m1 m2].freeze

  def test_a_call_edge_goes_only_to_the_class_its_receiver_names
    Hegel.test do |tc|
      defined = (0..2).to_h { |k| ["K#{k}", tc.draw(arrays(sampled_from(NAMES.flat_map { |name| [name, "self.#{name}"] }), unique: true, max_size: 4))] }
      calls = tc.draw(arrays(composite { |inner|
        [inner.draw(sampled_from(%w[instance singleton param ivar])), "K#{inner.draw(integers(min_value: 0, max_value: 2))}", inner.draw(sampled_from(NAMES))]
      }, min_size: 1, max_size: 6))
      classes = defined.map { |klass, defs| "class #{klass}\n#{defs.map { |name| "  def #{name}\n    1\n  end\n" }.join}end\n" }
      bodies = calls.map do |shape, klass, name|
        { "instance" => "#{klass}.new.#{name}", "singleton" => "#{klass}.#{name}", "param" => "value.#{name}", "ivar" => "@held.#{name}" }.fetch(shape)
      end
      caller_src = "class Caller\n  def initialize\n    @held = K0.new\n  end\n\n#{bodies.each_with_index.map { |body, i| "  def c#{i}(value)\n    #{body}\n  end\n" }.join("\n")}end\n"
      index = JitCatch::SourceIndex.parse(classes.join("\n") + caller_src, file: "lib/x.rb")
      edges = JitCatch::Changes.allocate.send(:edges_for, { "methods" => index.methods, "calls" => index.calls })
        .select { |edge| edge["from"].start_with?("Caller#c") }

      expected = calls.each_with_index.filter_map do |(shape, klass, name), i|
        owner, sep, defs_name = { "instance" => [klass, "#", name], "singleton" => [klass, ".", "self.#{name}"], "ivar" => ["K0", "#", name] }[shape]
        ["Caller#c#{i}", "#{owner}#{sep}#{name}"] if owner && defined.fetch(owner).include?(defs_name)
      end
      assert_equal expected.sort, edges.map { |edge| [edge["from"], edge["to"]] }.sort
    end
  end
end
