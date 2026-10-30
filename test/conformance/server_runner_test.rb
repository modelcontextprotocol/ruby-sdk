# frozen_string_literal: true

require "test_helper"
require_relative "../../conformance/server_runner"

module Conformance
  class ServerRunnerTest < ActiveSupport::TestCase
    EXPECTED_FAILURES_YML = File.expand_path("../../conformance/expected_failures.yml", __dir__)

    test "build_command runs the active suite by default" do
      command = ServerRunner.new.send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command runs a frozen requirement set and keeps the baseline" do
      command = ServerRunner.new(requirements: "2026-07-28").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--requirements",
          "2026-07-28",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end
  end
end
