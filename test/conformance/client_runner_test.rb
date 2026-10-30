# frozen_string_literal: true

require "test_helper"
require_relative "../../conformance/client_runner"

module Conformance
  class ClientRunnerTest < ActiveSupport::TestCase
    EXPECTED_FAILURES_YML = File.expand_path("../../conformance/expected_failures.yml", __dir__)
    CLIENT_SCRIPT = File.expand_path("../../conformance/client.rb", __dir__)

    test "build_command runs the full suite by default" do
      command = ClientRunner.new.send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "client",
          "--command",
          "bundle exec ruby #{CLIENT_SCRIPT}",
          "--suite",
          "all",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command replaces the suite selection with a frozen requirement set" do
      command = ClientRunner.new(requirements: "2026-07-28").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "client",
          "--command",
          "bundle exec ruby #{CLIENT_SCRIPT}",
          "--requirements",
          "2026-07-28",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command keeps the single scenario selection" do
      command = ClientRunner.new(scenario: "tools_call").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "client",
          "--command",
          "bundle exec ruby #{CLIENT_SCRIPT}",
          "--scenario",
          "tools_call",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end
  end
end
