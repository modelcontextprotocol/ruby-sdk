# frozen_string_literal: true

require "mcp"

require "minitest/autorun"
require "minitest/mock"
require "mocha/minitest"

require "active_support"
require "active_support/test_case"

require "sorbet-runtime" if RUBY_VERSION >= "3.0"

require_relative "instrumentation_test_helper"
