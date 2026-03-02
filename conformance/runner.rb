# frozen_string_literal: true

# Starts the conformance server and runs `npx @modelcontextprotocol/conformance` against it.
require "English"
require "net/http"
require_relative "server"

module Conformance
  class Runner
    # Timeout for waiting for the Puma server to start.
    SERVER_START_TIMEOUT = 20
    SERVER_POLL_INTERVAL = 0.5
    SERVER_HEALTH_CHECK_RETRIES = (SERVER_START_TIMEOUT / SERVER_POLL_INTERVAL).to_i

    def initialize(port: Server::DEFAULT_PORT, scenario: nil, spec_version: nil, verbose: false)
      @port = port
      @scenario = scenario
      @spec_version = spec_version
      @verbose = verbose
    end

    def run
      command = build_command
      server_pid = start_server

      run_conformance(command, server_pid: server_pid)
    end

    private

    def build_command
      expected_failures_yml = File.expand_path("expected_failures.yml", __dir__)

      npx_command = ["npx", "--yes", "@modelcontextprotocol/conformance", "server", "--url", "http://localhost:#{@port}/mcp"]
      npx_command += ["--scenario", @scenario] if @scenario
      npx_command += ["--spec-version", @spec_version] if @spec_version
      npx_command += ["--verbose"] if @verbose
      npx_command += ["--expected-failures", expected_failures_yml]
      npx_command
    end

    def start_server
      puts "Starting conformance server on port #{@port}..."

      server_pid = fork do
        Conformance::Server.new(port: @port).start
      end

      health_url = URI("http://localhost:#{@port}/health")
      ready = false
      SERVER_HEALTH_CHECK_RETRIES.times do
        begin
          response = Net::HTTP.get_response(health_url)
          if response.code == "200"
            ready = true
            break
          end
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::ReadTimeout
          # not ready yet
        end
        sleep(SERVER_POLL_INTERVAL)
      end

      unless ready
        warn("ERROR: Conformance server did not start within #{SERVER_START_TIMEOUT} seconds")
        terminate_server(server_pid)
        exit(1)
      end

      puts "Server ready. Running conformance tests..."

      server_pid
    end

    def run_conformance(command, server_pid:)
      puts "Command: #{command.join(" ")}\n\n"

      conformance_exit_code = nil
      begin
        system(*command)
        conformance_exit_code = $CHILD_STATUS.exitstatus
      ensure
        terminate_server(server_pid)
      end

      exit(conformance_exit_code || 1)
    end

    def terminate_server(pid)
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # process already exited
    ensure
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        # already reaped
      end
    end
  end
end
