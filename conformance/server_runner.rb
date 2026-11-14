# frozen_string_literal: true

# Starts the conformance server and runs `npx @modelcontextprotocol/conformance@alpha` against it.
require "English"
require "net/http"
require_relative "server"

module Conformance
  class ServerRunner
    # Timeout for waiting for the Puma server to start.
    SERVER_START_TIMEOUT = 20
    SERVER_POLL_INTERVAL = 0.5
    SERVER_HEALTH_CHECK_RETRIES = (SERVER_START_TIMEOUT / SERVER_POLL_INTERVAL).to_i

    # The referee runs on whatever Node `npx` finds. On Node 26, `fetch` rejects a promise without a reason when
    # a response body is cancelled on a pooled connection while the server's next frame is still in flight,
    # which the `server-sse-multiple-streams` scenario does right after reading a stream's priming event; nothing is
    # reported by that rejection, but it ends the referee process mid-suite. Node 22 and 24 (the version CI runs)
    # do not reject. The warning keeps the suite running; the referee's own checks decide the result as before.
    # Appended after any `NODE_OPTIONS` the environment sets, so it wins over an `--unhandled-rejections` value given
    # there: the referee is the only process this script starts, and a strict setting would end it the same way.
    REFEREE_NODE_OPTIONS = "--unhandled-rejections=warn"

    def initialize(port: Server::DEFAULT_PORT, scenario: nil, spec_version: nil, requirements: nil, verbose: false)
      @port = port
      @scenario = scenario
      @spec_version = spec_version
      @requirements = requirements
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

      npx_command = ["npx", "--yes", "@modelcontextprotocol/conformance@alpha", "server", "--url", "http://localhost:#{@port}/mcp"]
      # A requirement set already fixes which scenarios run, so it replaces the suite selection.
      # The referee's default `active` suite leaves out the extension-tagged scenarios (Skills, Tasks), which `all` selects,
      # as the client leg does; the areas the SDK does not implement are listed in expected_failures.yml.
      npx_command += if @requirements
        ["--requirements", @requirements]
      elsif @scenario
        ["--scenario", @scenario]
      else
        ["--suite", "all"]
      end
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
        system(referee_env, *command)
        conformance_exit_code = $CHILD_STATUS.exitstatus
      ensure
        terminate_server(server_pid)
      end

      exit(conformance_exit_code || 1) unless conformance_exit_code == 0
    end

    # Appends the referee's Node options to any the environment already sets.
    def referee_env
      options = [ENV["NODE_OPTIONS"], REFEREE_NODE_OPTIONS].compact.reject(&:empty?)

      { "NODE_OPTIONS" => options.join(" ") }
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
