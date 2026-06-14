# frozen_string_literal: true

require "mcp"

require "minitest/autorun"
require "minitest/mock"
require "mocha/minitest"

require "active_support"
require "active_support/test_case"

require "sorbet-runtime" if RUBY_VERSION >= "3.0"

require_relative "instrumentation_test_helper"

module DeprecationWarningTestHelper
  def assert_deprecation_warning(message_pattern, &block)
    original_verbose = $VERBOSE
    $VERBOSE = false
    assert_output(nil, message_pattern, &block)
  ensure
    $VERBOSE = original_verbose
  end

  def assert_no_deprecation_warning(&block)
    original_verbose = $VERBOSE
    $VERBOSE = false
    assert_output(nil, "", &block)
  ensure
    $VERBOSE = original_verbose
  end
end
