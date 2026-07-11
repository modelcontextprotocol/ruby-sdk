# frozen_string_literal: true

require "mcp"

require "minitest/autorun"
require "minitest/mock"
require "mocha/minitest"

# mocha relies on `Hash.ruby2_keywords_hash?`, which is absent on Ruby 2.7.0 and the earlier 2.7.x releases
# before it was backported. Those versions also lack the flag-setting APIs, so no hash is ever flagged as
# ruby2_keywords and returning `false` is correct. Without this shim, mocha raises `NoMethodError` and
# the suite cannot run on Ruby 2.7.0.
unless Hash.respond_to?(:ruby2_keywords_hash?)
  def Hash.ruby2_keywords_hash?(_hash)
    false
  end
end

require "active_support"
require "active_support/test_case"

require "sorbet-runtime" if RUBY_VERSION >= "3.0"

require_relative "instrumentation_test_helper"
require_relative "initialize_params_test_helper"
