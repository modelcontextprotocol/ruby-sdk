# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "timeout"
require_relative "../../json_rpc_handler"
require_relative "../configuration"
require_relative "../methods"
require_relative "../version"

module MCP
  class Client
    class Stdio
      # Seconds to wait for the server process to exit before sending SIGTERM.
      # Matches the Python and TypeScript SDKs' shutdown timeout:
      # https://github.com/modelcontextprotocol/python-sdk/blob/v1.26.0/src/mcp/client/stdio/__init__.py#L48
      # https://github.com/modelcontextprotocol/typescript-sdk/blob/v1.27.1/src/client/stdio.ts#L221
      CLOSE_TIMEOUT = 2
      STDERR_READ_SIZE = 4096

      attr_reader :command, :args, :env

      def initialize(command:, args: [], env: nil, read_timeout: nil)
        @command = command
        @args = args
        @env = env
        @read_timeout = read_timeout
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @stderr_thread = nil
        @started = false
        @initialized = false
      end

      def send_request(request:)
        start unless @started
        initialize_session unless @initialized

        write_message(request)
        read_response(request)
      end

      def start
        raise "MCP::Client::Stdio already started" if @started

        spawn_env = @env || {}
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(spawn_env, @command, *@args)
        @stdout.set_encoding("UTF-8")
        @stdin.set_encoding("UTF-8")

        # Drain stderr in the background to prevent the pipe buffer from filling up,
        # which would cause the server process to block and deadlock.
        @stderr_thread = Thread.new do
          loop do
            @stderr.readpartial(STDERR_READ_SIZE)
          end
        rescue IOError
          nil
        end

        @started = true
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC => e
        raise RequestHandlerError.new(
          "Failed to spawn server process: #{e.message}",
          {},
          error_type: :internal_error,
          original_error: e,
        )
      end

      def close
        return unless @started

        @stdin.close
        @stdout.close
        @stderr.close

        begin
          Timeout.timeout(CLOSE_TIMEOUT) { @wait_thread.value }
        rescue Timeout::Error
          begin
            Process.kill("TERM", @wait_thread.pid)
            Timeout.timeout(CLOSE_TIMEOUT) { @wait_thread.value }
          rescue Timeout::Error
            begin
              Process.kill("KILL", @wait_thread.pid)
            rescue Errno::ESRCH
              nil
            end
          rescue Errno::ESRCH
            nil
          end
        end

        @stderr_thread.join(CLOSE_TIMEOUT)
        @started = false
        @initialized = false
      end

      private

      # The client MUST send a protocol version it supports. This SHOULD be the latest version.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#version-negotiation
      #
      # Always sends `LATEST_STABLE_PROTOCOL_VERSION`, matching the Python and TypeScript SDKs:
      # https://github.com/modelcontextprotocol/python-sdk/blob/v1.26.0/src/mcp/client/session.py#L175
      # https://github.com/modelcontextprotocol/typescript-sdk/blob/v1.27.1/src/client/index.ts#L495
      def initialize_session
        init_request = {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          id: SecureRandom.uuid,
          method: MCP::Methods::INITIALIZE,
          params: {
            protocolVersion: MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION,
            capabilities: {},
            clientInfo: { name: "mcp-ruby-client", version: MCP::VERSION },
          },
        }

        write_message(init_request)
        response = read_response(init_request)

        if response.key?("error")
          error = response["error"]
          raise RequestHandlerError.new(
            "Server initialization failed: #{error["message"]}",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        unless response.key?("result")
          raise RequestHandlerError.new(
            "Server initialization failed: missing result in response",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        notification = {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          method: MCP::Methods::NOTIFICATIONS_INITIALIZED,
        }
        write_message(notification)

        @initialized = true
      end

      def write_message(message)
        ensure_running!
        json = JSON.generate(message)
        @stdin.puts(json)
        @stdin.flush
      rescue IOError, Errno::EPIPE => e
        raise RequestHandlerError.new(
          "Failed to write to server process",
          {},
          error_type: :internal_error,
          original_error: e,
        )
      end

      def read_response(request)
        request_id = request[:id] || request["id"]
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        loop do
          ensure_running!
          wait_for_readable!(method, params) if @read_timeout
          line = @stdout.gets
          raise_connection_error!(method, params) if line.nil?

          parsed = JSON.parse(line.strip)

          next unless parsed.key?("id")

          return parsed if parsed["id"] == request_id
        end
      rescue JSON::ParserError => e
        raise RequestHandlerError.new(
          "Failed to parse server response",
          { method: method, params: params },
          error_type: :internal_error,
          original_error: e,
        )
      end

      def ensure_running!
        return if @wait_thread.alive?

        raise RequestHandlerError.new(
          "Server process has exited",
          {},
          error_type: :internal_error,
        )
      end

      def wait_for_readable!(method, params)
        ready = @stdout.wait_readable(@read_timeout)
        return if ready

        raise RequestHandlerError.new(
          "Timed out waiting for server response",
          { method: method, params: params },
          error_type: :internal_error,
        )
      end

      def raise_connection_error!(method, params)
        raise RequestHandlerError.new(
          "Server process closed stdout unexpectedly",
          { method: method, params: params },
          error_type: :internal_error,
        )
      end
    end
  end
end
