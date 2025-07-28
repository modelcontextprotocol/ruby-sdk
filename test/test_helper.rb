# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "bundler/setup"
require "mcp"

require "minitest/autorun"
require "minitest/reporters"
require "minitest/mock"
require "mocha/minitest"

require "active_support"
require "active_support/test_case"

require "sorbet-runtime"

require_relative "instrumentation_test_helper"

unless ENV["RM_INFO"]
  # RubyMine does not support Minitest reporters, so we use the default reporter
  Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)
end

module ActiveSupport
  class TestCase
  end
end
