# frozen_string_literal: true

require_relative "../test_helper"

class TestShopDemo < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_recorded_shop_runs_match_a_fresh_fixture
    Dir.mktmpdir("jitcatch-shop-") do |dir|
      repo = File.join(dir, "shop")
      setup = File.join(ROOT, "script/setup_shop")
      ok = system(RbConfig.ruby, setup, repo, out: File::NULL, err: File::NULL)
      assert ok, "setup_shop failed"

      {
        "regression" => "regression",
        "intended" => "intended"
      }.each do |ref, dirname|
        recorded = File.join(ROOT, "examples/runs", dirname)
        context, context_err, context_status = cli("context", "--repo", repo, "base", ref)
        assert_equal 0, context_status.exitstatus, context_err
        assert_equal File.read(File.join(recorded, "context.txt")), context

        run, run_err, run_status = cli(
          "run", "--repo", repo, "base", ref, File.join(recorded, "tests")
        )
        assert_equal 0, run_status.exitstatus, run_err
        assert_equal File.read(File.join(recorded, "run.txt")), run
      end
    end
  end

  def cli(*args)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/jitcatch"), *args)
  end
end
