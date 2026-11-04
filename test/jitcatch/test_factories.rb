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
        factory :lost, parent: :nowhere
      end
    RUBY

    found = JitCatch::Factories.read("spec/factories.rb" => source).map { |factory| factory.to_h.values_at(:name, :class_name, :line, :reason) }

    assert_equal [
      [nil, nil, 2, "its name is not a symbol or a string"],
      ["child", nil, 3, "parent: is not a symbol or a string"],
      ["nested", nil, 4, "class: is not a constant, a string, or a symbol"],
      ["inner", nil, 5, "class: is not a constant, a string, or a symbol"],
      ["admin/api_key", "Billing::Plan", 7, nil],
      ["lost", nil, 8, "its parent :nowhere is not a factory read here"]
    ], found
  end

  # FactoryBot builds an association with the factory itself, so
  # `create(:loan)` saves a Borrower too: through a bare `borrower` that
  # names a factory, `association`, or an attribute block that calls it,
  # in the factory or in one it inherits from. A trait's association runs
  # only when a test names the trait, so it is not followed.
  def test_a_factory_builds_the_classes_of_its_associations
    source = <<~RUBY
      FactoryBot.define do
        factory :borrower
        factory :officer, class: "Staff::Officer"
        factory :branch
        factory :loan do
          borrower
          amount_cents { 1 }
          rate 3
          memo { }
          code { code_for(:branch) }
          approver { association :officer }
          trait(:filed) { association :branch }

          factory :big_loan
        end
        factory :review do
          association :subject, strategy: :build, factory: :loan
          association :reviewer, factory: [:branch, :busy]
          note
        end
        factory :remark, parent: :review
      end
    RUBY

    found = JitCatch::Factories.read("spec/factories.rb" => source).to_h { |factory| [factory.name, factory.builds] }

    assert_equal({
      "borrower" => [], "officer" => [], "branch" => [],
      "loan" => %w[Borrower Staff::Officer], "big_loan" => %w[Borrower Staff::Officer],
      "review" => %w[Borrower Branch Loan Staff::Officer], "remark" => %w[Borrower Branch Loan Staff::Officer]
    }, found)
  end

  def test_factory_files_are_under_spec_or_test_factories
    assert_equal [true, true, true, false, false],
      %w[spec/factories.rb test/factories/loans.rb engines/a/spec/factories/x.rb spec/models/loan_spec.rb lib/factories.rb].map { |path| JitCatch::Factories.file?(path) }
  end
end
