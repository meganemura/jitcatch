# frozen_string_literal: true

require_relative "../test_helper"

class TestFramework < Minitest::Test
  def test_a_spec_file_is_rspec_unless_it_requires_minitest
    assert_equal JitCatch::Framework::RSpec, JitCatch::Framework.for("cart_spec.rb", %(require "spec_helper"\n))
    assert_equal JitCatch::Framework::Minitest, JitCatch::Framework.for("cart_spec.rb", %(require "minitest/autorun"\n))
    assert_equal JitCatch::Framework::Minitest, JitCatch::Framework.for("cart_test.rb", %(require "spec_helper"\n))
  end

  def test_named_files_are_tests_and_specs
    assert_equal [true, true, true, false, false], %w[a/test_cart.rb cart_test.rb cart_spec.rb cart.rb spec_helper.rb].map { |path| JitCatch::Framework.named?(path) }
  end

  def test_each_framework_runs_the_file_it_is_given
    assert_equal ["-r#{File.expand_path("../../lib/jitcatch/minitest_cause.rb", __dir__)}", ".jitcatch/a_test.rb", "-v", "--seed", "1"], JitCatch::Framework::Minitest.arguments(".jitcatch/a_test.rb")
    assert_equal ".jitcatch/a_spec.rb", JitCatch::Framework::RSpec.arguments(".jitcatch/a_spec.rb").last
    assert_includes JitCatch::Framework::RSpec.arguments("x"), JitCatch::Framework::REPORT
  end

  def test_a_rerun_names_one_test_or_the_whole_file
    assert_equal "ruby -Ilib -I. {tests}/a_test.rb -n A#test_b", JitCatch::Framework::Minitest.rerun("a_test.rb", "A#test_b", nil)
    assert_equal "ruby -Ilib -I. {tests}/a_test.rb", JitCatch::Framework::Minitest.rerun("a_test.rb", nil, nil)
    launch = %('require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Core::RubyProject.instance_variable_set(:@project_root, Dir.pwd); RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))')
    assert_equal "ruby -Ilib -I. -e #{launch} {tests}/a_spec.rb:7", JitCatch::Framework::RSpec.rerun("a_spec.rb", "A b", 7)
    assert_equal "ruby -Ilib -I. -e #{launch} {tests}/a_spec.rb", JitCatch::Framework::RSpec.rerun("a_spec.rb", nil, nil)
    short = %('require "rspec/core"; require "rspec/support/object_formatter"; RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil; exit(RSpec::Core::Runner.run(ARGV))')
    assert_equal "ruby -Ilib -I. -e #{short} {tests}/a_spec.rb:7", JitCatch::Framework::RSpec.rerun("a_spec.rb", "A b", 7, pin_root: false)
  end
end
