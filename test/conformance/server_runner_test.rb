# frozen_string_literal: true

require "test_helper"
require_relative "../../conformance/server_runner"

module Conformance
  class ServerRunnerTest < ActiveSupport::TestCase
    EXPECTED_FAILURES_YML = File.expand_path("../../conformance/expected_failures.yml", __dir__)

    test "build_command runs the full suite by default" do
      command = ServerRunner.new.send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--suite",
          "all",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command keeps the single scenario selection" do
      command = ServerRunner.new(scenario: "ping").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--scenario",
          "ping",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command pins the full suite to a spec version" do
      command = ServerRunner.new(spec_version: "2025-11-25").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--suite",
          "all",
          "--spec-version",
          "2025-11-25",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command pins a single scenario to a spec version" do
      command = ServerRunner.new(scenario: "ping", spec_version: "2025-11-25").send(:build_command)

      assert_equal(
        [
          "npx",
          "--yes",
          "@modelcontextprotocol/conformance@alpha",
          "server",
          "--url",
          "http://localhost:#{Server::DEFAULT_PORT}/mcp",
          "--scenario",
          "ping",
          "--spec-version",
          "2025-11-25",
          "--expected-failures",
          EXPECTED_FAILURES_YML,
        ],
        command,
      )
    end

    test "build_command lets a requirement set replace a scenario selection" do
      command = ServerRunner.new(requirements: "2026-07-28", scenario: "ping").send(:build_command)

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

    test "the referee runs with unhandled rejections downgraded to warnings, keeping the NODE_OPTIONS already set" do
      original = ENV["NODE_OPTIONS"]
      runner = ServerRunner.new

      ENV.delete("NODE_OPTIONS")
      assert_equal({ "NODE_OPTIONS" => "--unhandled-rejections=warn" }, runner.send(:referee_env))

      ENV["NODE_OPTIONS"] = "--max-old-space-size=512"
      assert_equal({ "NODE_OPTIONS" => "--max-old-space-size=512 --unhandled-rejections=warn" }, runner.send(:referee_env))
    ensure
      if original
        ENV["NODE_OPTIONS"] = original
      else
        ENV.delete("NODE_OPTIONS")
      end
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
