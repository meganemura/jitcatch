# frozen_string_literal: true

require_relative "../test_helper"

class TestFactories < Minitest::Test
  # A factory whose class the source does not settle has a reason and no
  # class, and a name a run computes has no name either.
  def test_a_factory_the_source_does_not_settle_has_a_reason_and_no_class
    source = <<~RUBY
      FactoryBot.define do
        factory name_of(:x)
        factory :child, parent: parent_name
        factory :nested, class: kind do
          factory :inner
        end
        factory "admin/api_key", class: :"billing/plan"
      end
    RUBY

    found = JitCatch::Factories.read("spec/factories.rb" => source).map { |factory| factory.to_h.values_at(:name, :class_name, :line, :reason) }

    assert_equal [
      [nil, nil, 2, "its name is not a symbol or a string"],
      ["child", nil, 3, "parent: is not a symbol or a string"],
      ["nested", nil, 4, "class: is not a constant, a string, or a symbol"],
      ["inner", nil, 5, "class: is not a constant, a string, or a symbol"],
      ["admin/api_key", "Billing::Plan", 7, nil]
    ], found
  end

  def test_factory_files_are_under_spec_or_test_factories
    assert_equal [true, true, true, false, false],
      %w[spec/factories.rb test/factories/loans.rb engines/a/spec/factories/x.rb spec/models/loan_spec.rb lib/factories.rb].map { |path| JitCatch::Factories.file?(path) }
  end
end
