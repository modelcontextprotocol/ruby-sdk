# frozen_string_literal: true

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
