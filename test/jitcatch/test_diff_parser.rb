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

    files = JitCatch::DiffParser.parse(diff)
    assert_equal ["lib/cart.rb", "README.md"], files.map { |file| file["new_path"] }
    cart = files.first
    assert JitCatch::DiffParser.overlaps?(4, 4, cart["hunks"], "new")
    assert JitCatch::DiffParser.overlaps?(13, 15, cart["hunks"], "new")
    refute JitCatch::DiffParser.overlaps?(6, 11, cart["hunks"], "new")

    status = JitCatch::DiffParser.name_status("M\tlib/cart.rb\nA\tlib/new.rb\n")
    assert_equal [
      { "status" => "M", "file" => "lib/cart.rb" },
      { "status" => "A", "file" => "lib/new.rb" }
    ], status
  end
  def test_added_files_bare_counts_and_headerless_lines
    diff = <<~DIFF
      --- a/stray.rb
      @@ -1 +1 @@
      diff --git a/bin/tool b/bin/tool
      old mode 100644
      new mode 100755
      diff --git a/lib/new.rb b/lib/new.rb
      --- /dev/null
      +++ b/lib/new.rb
      @@ -0,0 +1,2 @@
      diff --git a/lib/old.rb b/lib/old.rb
      --- a/lib/old.rb
      +++ /dev/null
      @@ -3 +2,0 @@
    DIFF
    assert_equal [
      { "old_path" => nil, "new_path" => nil, "hunks" => [] },
      { "old_path" => nil, "new_path" => "lib/new.rb",
        "hunks" => [{ "old_start" => 0, "old_count" => 0, "new_start" => 1, "new_count" => 2 }] },
      { "old_path" => "lib/old.rb", "new_path" => nil,
        "hunks" => [{ "old_start" => 3, "old_count" => 1, "new_start" => 2, "new_count" => 0 }] }
    ], JitCatch::DiffParser.parse(diff)
  end

  def test_an_empty_side_of_a_hunk_overlaps_nothing
    hunks = [{ "old_start" => 5, "old_count" => 0, "new_start" => 6, "new_count" => 2 }]
    refute JitCatch::DiffParser.overlaps?(1, 10, hunks, "old")
    assert JitCatch::DiffParser.overlaps?(7, 9, hunks, "new")
    assert_equal [{ "status" => "M", "file" => "a.rb" }], JitCatch::DiffParser.name_status("\nM\ta.rb\n\n")
  end
end
