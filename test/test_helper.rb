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

Minitest::Reporters.use!(Minitest::Reporters::ProgressReporter.new)

module ActiveSupport
  class TestCase
    self.file_fixture_path = File.join(__dir__, "fixtures/files")
  end
end
