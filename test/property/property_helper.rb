# frozen_string_literal: true

require_relative "../test_helper"
require "hegel"

class Minitest::Test
  include Hegel::Syntax::Methods

  # Any line, frame-shaped or not, quoted with "# " or indented four spaces.
  LINE_OF_ANY_SHAPE = "(    |# |[ +-]{0,2})([a-z./]{1,8}:[0-9]{1,3}:in '[a-z]{1,5}'|[a-z]{1,4}( [a-z]{1,4}){0,2})"
end
