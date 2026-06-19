# frozen_string_literal: true

# Runs `npx @modelcontextprotocol/conformance client` against the conformance client script.
require "English"

module Conformance
  class ClientRunner
    def initialize(scenario: nil, spec_version: nil, verbose: false)
      @scenario = scenario
      @spec_version = spec_version
      @verbose = verbose
    end

    def run
      command = build_command
      puts "Command: #{command.join(" ")}\n\n"

      system(*command)
      conformance_exit_code = $CHILD_STATUS.exitstatus
      exit(conformance_exit_code || 1) unless conformance_exit_code == 0
    end

    private

    def build_command
      expected_failures_yml = File.expand_path("expected_failures.yml", __dir__)
      client_script = File.expand_path("client.rb", __dir__)

      npx_command = [
        "npx",
        "--yes",
        "@modelcontextprotocol/conformance",
        "client",
        "--command",
        "bundle exec ruby #{client_script}",
      ]
      npx_command += if @scenario
        ["--scenario", @scenario]
      else
        ["--suite", "all"]
      end
      npx_command += ["--spec-version", @spec_version] if @spec_version
      npx_command += ["--verbose"] if @verbose
      npx_command += ["--expected-failures", expected_failures_yml]
      npx_command
    end
  end
end
