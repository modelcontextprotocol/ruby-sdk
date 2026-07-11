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

      # Default upper bound on a single newline-delimited frame read from the
      # server's stdout. CRuby's `IO#gets` without a limit accumulates bytes until a
      # newline arrives, so a spawned server that never emits one can grow a single
      # String until the host process is OOM-killed. 4 MiB is large enough for any
      # realistic JSON-RPC frame, including base64-embedded images.
      MAX_LINE_BYTES = 4 * 1024 * 1024

      attr_reader :command, :args, :env, :server_info

      def initialize(command:, args: [], env: nil, read_timeout: nil, max_line_bytes: MAX_LINE_BYTES)
        # Reject `nil` or non-positive values: `IO#gets("\n", nil)` and a negative
        # limit read without an upper bound, which would silently disable the
        # protection this option exists to provide.
        unless max_line_bytes.is_a?(Integer) && max_line_bytes > 0
          raise ArgumentError, "max_line_bytes must be a positive Integer"
        end

        @command = command
        @args = args
        @env = env
        @read_timeout = read_timeout
        @max_line_bytes = max_line_bytes
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @stderr_thread = nil
        @started = false
        @initialized = false
        @server_info = nil
        # Serializes writes to `@stdin` so a request line and a notification line emitted from
        # different threads (e.g. cancellation) cannot interleave on the wire.
        @write_mutex = Mutex.new
      end

      # Performs the MCP `initialize` handshake: sends an `initialize` request
      # followed by the required `notifications/initialized` notification. The
      # server's `InitializeResult` (protocol version, capabilities, server
      # info, instructions) is cached on the transport and returned.
      #
      # Idempotent: a second call returns the cached `InitializeResult` without
      # contacting the server. After `close`, state is cleared and `connect`
      # will handshake again. Spawns the subprocess via `start` if it has not
      # been started yet.
      #
      # @param client_info [Hash, nil] `{ name:, version: }` identifying the client.
      #   Defaults to `{ name: "mcp-ruby-client", version: MCP::VERSION }`.
      # @param protocol_version [String, nil] Protocol version to offer. Defaults
      #   to `MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION`.
      # @param capabilities [Hash] Capabilities advertised by the client. Defaults to `{}`.
      # @return [Hash] The server's `InitializeResult`.
      # @raise [RequestHandlerError] If the server responds with a JSON-RPC error,
      #   a malformed result, or an unsupported protocol version.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization
      def connect(client_info: nil, protocol_version: nil, capabilities: {})
        return @server_info if @initialized

        start unless @started

        client_info ||= { name: "mcp-ruby-client", version: MCP::VERSION }
        protocol_version ||= MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION

        init_request = {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          id: SecureRandom.uuid,
          method: MCP::Methods::INITIALIZE,
          params: {
            protocolVersion: protocol_version,
            capabilities: capabilities,
            clientInfo: client_info,
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

        unless response["result"].is_a?(Hash)
          raise RequestHandlerError.new(
            "Server initialization failed: missing result in response",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        @server_info = response["result"]

        negotiated_protocol_version = @server_info["protocolVersion"]
        unless MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(negotiated_protocol_version)
          # Per spec, if the client does not support the server's returned protocol version,
          # the client SHOULD disconnect. Roll back the cached `InitializeResult` before
          # raising so a retry starts without a stale `server_info`.
          # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#version-negotiation
          @server_info = nil
          raise RequestHandlerError.new(
            "Server initialization failed: unsupported protocol version #{negotiated_protocol_version.inspect}",
            { method: MCP::Methods::INITIALIZE },
            error_type: :internal_error,
          )
        end

        begin
          notification = {
            jsonrpc: JsonRpcHandler::Version::V2_0,
            method: MCP::Methods::NOTIFICATIONS_INITIALIZED,
          }
          write_message(notification)
        rescue StandardError
          @server_info = nil
          raise
        end

        @initialized = true
        @server_info
      end

      # Returns true once `connect` has completed the handshake. Returns false before the handshake and after `close`.
      def connected?
        @initialized
      end

      # Transports may yield once the request line has been written to `@stdin`.
      # `MCP::Client#dispatch_with_cancellation` uses this signal to ensure a `notifications/cancelled`
      # write does not race ahead of the request write on the wire. The yield happens inside `@write_mutex`,
      # so any subsequent `send_notification` write waits for the mutex and is guaranteed to land after the request.
      def send_request(request:)
        raise "MCP::Client#connect must be called before sending requests." unless @initialized

        @write_mutex.synchronize do
          write_message(request)
          yield if block_given?
        end
        read_response(request)
      end

      # Sends a JSON-RPC notification (no response expected). Used by `Client#cancel` to deliver
      # `notifications/cancelled` for an in-flight request.
      def send_notification(notification:)
        start unless @started
        connect unless @initialized

        @write_mutex.synchronize { write_message(notification) }
        nil
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
        @server_info = nil
      end

      private

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
          line = read_line(method, params)
          raise_connection_error!(method, params) if line.nil?

          parsed = JSON.parse(line.strip)

          # A JSON-RPC message is an object; skip a non-object frame (array or scalar)
          # the same way as a frame without an id.
          next unless parsed.is_a?(Hash) && parsed.key?("id")

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

      # Reads one newline-delimited frame from the server's stdout, bounded by `@max_line_bytes`.
      # Returns the line (including its trailing newline) or `nil` at EOF. Raises when the limit
      # is reached before a newline arrives, which signals a server streaming an unbounded frame.
      # A short final frame without a trailing newline (EOF) is still returned, since its length
      # stays under the limit.
      def read_line(method, params)
        line = @stdout.gets("\n", @max_line_bytes)
        return line unless line && !line.end_with?("\n") && line.bytesize >= @max_line_bytes

        # The over-limit frame leaves leftover bytes in the pipe, so the stream is desynced and
        # cannot be resumed. Close before raising so a later `send_request` fails cleanly instead
        # of parsing a truncated frame.
        begin
          close
        rescue StandardError
          nil
        end

        raise RequestHandlerError.new(
          "Server response frame exceeds #{@max_line_bytes} bytes without a newline",
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
