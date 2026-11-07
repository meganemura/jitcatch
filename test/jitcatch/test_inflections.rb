# frozen_string_literal: true

require_relative "../test_helper"

class TestInflections < Minitest::Test
  APP = <<~RUBY
    ActiveSupport::Inflector.inflections(:en) do |inflect|
      inflect.acronym "API"
      inflect.irregular "cactus", "cacti"
      inflect.uncountable %w[staff geese]
      inflect.plural(/^(ox)$/i, '\\1es')
      inflect.singular(SINGULAR_RULE, "x")
      inflect.irregular "fish", "fishes"
      inflect.irregular "goose", "geese"
      inflect.irregular "cow", "kine"
      inflect.plural("money", "monies")
      inflect.plural(/^jean$/i, "jeans")
      inflect.singular("species", "specie")
      inflect.singular(/^informations$/i, "information")
    end
  RUBY

  # Each answer is what Active Support 8.1.4.1 gave with the same
  # initializer loaded.
  def test_a_word_takes_the_forms_active_support_gives_it
    inflections = JitCatch::Inflections.read(APP)

    {
      "books" => "book", "categories" => "category", "statuses" => "status", "boxes" => "box", "news" => "news",
      "people" => "person", "salespeople" => "salesperson", "cacti" => "cactus", "equipment" => "equipment",
      "wolves" => "wolf", "shelves" => "shelf", "octopi" => "octopus", "mice" => "mouse", "indices" => "index",
      "matrices" => "matrix", "analyses" => "analysis", "quizzes" => "quiz", "buses" => "bus", "knives" => "knife",
      "series" => "series", "movies" => "movie", "axes" => "axis", "oxen" => "ox", "databases" => "database",
      "crises" => "crisis", "addresses" => "address", "potatoes" => "potato", "staff" => "staff", "children" => "child",
      "geese" => "goose", "kine" => "cow", "jeans" => "jean", "species" => "specie", "fishes" => "fish", "sheep" => "sheep",
      "cactus" => "cactus", "cow" => "cow", "Cow" => "Cow", "Kine" => "Cow"
    }.each { |plural, singular| assert_equal singular, inflections.singularize(plural), plural }
    {
      "book" => "books", "person" => "people", "status" => "statuses", "mouse" => "mice", "child" => "children",
      "staff" => "staff", "cactus" => "cacti", "ox" => "oxes", "profile" => "profiles",
      "sheep" => "sheep", "fish" => "fishes", "money" => "monies", "jean" => "jeans", "information" => "informations", "cow" => "kine",
      "cacti" => "cacti", "kine" => "kine", "Cow" => "Kine", "Kine" => "Kine"
    }.each { |singular, plural| assert_equal plural, inflections.pluralize(singular), singular }
    assert_equal %w[APIKeys Apis BookReviews], %w[api_keys apis book_reviews].map { |word| inflections.camelize(word) }
  end

  def test_without_the_file_the_rails_defaults_hold
    inflections = JitCatch::Inflections.read(nil)

    assert_equal %w[cactu ApiKeys oxen], [inflections.singularize("cactus"), inflections.camelize("api_keys"), inflections.pluralize("ox")]
  end

  # Each answer is what Active Support 8.1.4.1's String#underscore gave.
  def test_a_class_name_takes_the_snake_case_active_support_gives_it
    inflections = JitCatch::Inflections.rails

    assert_equal %w[closures_controller api_keys_controller order_item html_parser book2_shelf v2_api],
      %w[ClosuresController APIKeysController OrderItem HTMLParser Book2Shelf V2Api].map { |word| inflections.underscore(word) }
  end
end
