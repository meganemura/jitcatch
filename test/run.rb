# frozen_string_literal: true

Dir[File.expand_path("jitcatch/test_*.rb", __dir__)].sort.each { |file| require file }
