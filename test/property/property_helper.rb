# frozen_string_literal: true

require_relative "../test_helper"
require "hegel"

class Minitest::Test
  include Hegel::Syntax::Methods
end
