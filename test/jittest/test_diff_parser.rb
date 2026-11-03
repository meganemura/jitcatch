# frozen_string_literal: true

require_relative "../test_helper"

class TestDiffParser < Minitest::Test
  def test_parses_hunks_and_overlap
    diff = <<~DIFF
      diff --git a/lib/cart.rb b/lib/cart.rb
      index 111..222 100644
      --- a/lib/cart.rb
      +++ b/lib/cart.rb
      @@ -4 +4 @@ class Cart
      -  LIMIT = 10
      +  LIMIT = 5
      @@ -12,0 +13,3 @@ class Cart
      +  def coupon
      +    1
      +  end
      diff --git a/README.md b/README.md
      --- a/README.md
      +++ b/README.md
      @@ -1 +1 @@
      -old
      +new
    DIFF

    files = JitTest::DiffParser.parse(diff)
    assert_equal ["lib/cart.rb", "README.md"], files.map { |file| file["new_path"] }
    cart = files.first
    assert JitTest::DiffParser.overlaps?(4, 4, cart["hunks"], "new")
    assert JitTest::DiffParser.overlaps?(13, 15, cart["hunks"], "new")
    refute JitTest::DiffParser.overlaps?(6, 11, cart["hunks"], "new")

    status = JitTest::DiffParser.name_status("M\tlib/cart.rb\nA\tlib/new.rb\n")
    assert_equal [
      { "status" => "M", "file" => "lib/cart.rb" },
      { "status" => "A", "file" => "lib/new.rb" }
    ], status
  end
end
