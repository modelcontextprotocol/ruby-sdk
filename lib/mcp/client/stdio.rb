# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "timeout"
require_relative "../../json_rpc_handler"
require_relative "../configuration"
require_relative "../methods"
require_relative "../protocol_deprecations"
require_relative "../version"
require_relative "modern_envelope"

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

      # Seconds the `server/discover` probe may wait when no `read_timeout` was configured.
      # A compliant legacy server answers the probe with `-32601` immediately, but a non-compliant one
      # that silently drops unknown methods would otherwise block `connect(mode: :auto)` forever.
      # Matches the C# SDK's `DiscoverProbeTimeout` default.
      DEFAULT_DISCOVER_PROBE_TIMEOUT = 5

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
        @modern_protocol_version = nil
        @modern_client_info = nil
        @modern_capabilities = nil
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
      # @param protocol_version [String, nil] Protocol version to offer on the legacy handshake.
      #   Defaults to `MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION`; a modern version
      #   raises `ArgumentError` here (modern versions are selected via `mode: :modern`/`:auto`).
      # @param capabilities [Hash] Capabilities advertised by the client. Defaults to `{}`.
      # @return [Hash] The server's `InitializeResult`.
      # @raise [RequestHandlerError] If the server responds with a JSON-RPC error,
      #   a malformed result, or an unsupported protocol version.
      # @param mode [Symbol] Lifecycle selection (SEP-2575): `:legacy` (default) performs
      #   the handshake below, `:modern` skips it and probes `server/discover`,
      #   and `:auto` probes `server/discover` first, falling back to the legacy handshake
      #   when the server does not serve a mutually supported modern version.
      # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization
      def connect(client_info: nil, protocol_version: nil, capabilities: {}, mode: :legacy)
        return @server_info if connected?

        # Validated before `start` so a pure argument error never spawns the server process.
        MCP::Configuration.reject_modern_handshake_version!(protocol_version) if mode == :legacy

        start unless @started

        client_info ||= { name: "mcp-ruby-client", version: MCP::VERSION }

        case mode
        when :legacy
          connect_legacy(client_info: client_info, protocol_version: protocol_version, capabilities: capabilities)
        when :modern
          connect_modern(client_info: client_info, protocol_version: protocol_version, capabilities: capabilities)
        when :auto
          connect_auto(client_info: client_info, protocol_version: protocol_version, capabilities: capabilities)
        else
          raise ArgumentError, "mode must be :legacy, :modern, or :auto"
        end
      end

      # Whether the transport operates in the stateless modern lifecycle (SEP-2575):
      # no handshake was performed and every request carries the `_meta` envelope.
      def modern?
        !@modern_client_info.nil?
      end

      # The protocol version in use on this connection, independent of its era:
      # negotiated by `initialize` (legacy) or adopted via `server/discover` (modern).
      # Returns `nil` before `connect` and after `close`.
      def protocol_version
        @modern_protocol_version || (@server_info && @server_info["protocolVersion"])
      end

      # Returns true once `connect` has completed the handshake or adopted the modern lifecycle.
      # Returns false before the handshake and after `close`.
      def connected?
        @initialized || modern?
      end

      # Transports may yield once the request line has been written to `@stdin`.
      # `MCP::Client#dispatch_with_cancellation` uses this signal to ensure a `notifications/cancelled`
      # write does not race ahead of the request write on the wire. The yield happens inside `@write_mutex`,
      # so any subsequent `send_notification` write waits for the mutex and is guaranteed to land after the request.
      def send_request(request:)
        method = request[:method] || request["method"]
        if method == MCP::Methods::SERVER_DISCOVER
          # `server/discover` (SEP-2575) is sessionless capability discovery that
          # works before (or instead of) `connect`.
          start unless @started
        elsif !connected?
          raise "MCP::Client#connect must be called before sending requests."
        end

        request = stamp_modern(request)

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
        connect unless connected?

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
        leave_modern_mode
      end

      private

      def connect_legacy(client_info:, protocol_version:, capabilities:)
        protocol_version ||= MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION

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
        unless MCP::Configuration::SUPPORTED_HANDSHAKE_PROTOCOL_VERSIONS.include?(negotiated_protocol_version)
          # Per spec, if the client does not support the server's returned protocol version,
          # the client SHOULD disconnect. A modern version is rejected along with unknown ones:
          # the handshake settles on a legacy version by definition, and the TypeScript and Python clients refuse
          # a modern counter-offer the same way. Roll back the cached `InitializeResult` before raising
          # so a retry starts without a stale `server_info`.
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

      # Enters the modern lifecycle by probing `server/discover` at the requested (or latest) modern version.
      # No `initialize` or `notifications/initialized` is sent; the probe response becomes `server_info`.
      def connect_modern(client_info:, protocol_version:, capabilities:)
        version = protocol_version || MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION
        unless MCP::Configuration.modern_protocol_version?(version)
          raise ArgumentError, "protocol_version #{version.inspect} is not a supported modern protocol version"
        end

        @modern_protocol_version = version
        @modern_client_info = client_info
        @modern_capabilities = capabilities || {}

        begin
          result = with_probe_read_timeout { probe_discover }
        rescue StandardError
          leave_modern_mode
          raise
        end

        supported = result["supportedVersions"]
        unless supported.is_a?(Array) && supported.include?(version)
          leave_modern_mode
          raise RequestHandlerError.new(
            "Server discovery failed: no mutually supported modern protocol version " \
              "(server supports #{supported.inspect})",
            { method: MCP::Methods::SERVER_DISCOVER },
            error_type: :internal_error,
          )
        end

        # SEP-2577 deprecates roots and sampling at 2026-07-28, the revision every modern connection speaks,
        # so the warning lives here now that the handshake cannot land on one.
        MCP::ProtocolDeprecations.warn_for_client_capabilities(capabilities, protocol_version: version, uplevel: 1)

        @server_info = result
        @server_info
      end

      # Probes `server/discover` and adopts the modern lifecycle when the server serves
      # a mutually supported modern version; otherwise falls back to the legacy handshake.
      # The fallback intentionally covers a successful discovery without a mutual modern
      # version as well: during the 2026-07-28 rollout a server may answer discovery while
      # only serving legacy versions.
      def connect_auto(client_info:, protocol_version:, capabilities:)
        modern_pin = protocol_version if protocol_version && MCP::Configuration.modern_protocol_version?(protocol_version)
        connect_modern(client_info: client_info, protocol_version: modern_pin, capabilities: capabilities)
      rescue RequestHandlerError
        # An explicitly requested modern version is never downgraded by the fallback: the legacy handshake cannot negotiate it,
        # so the probe's failure is the real answer and propagates.
        raise if modern_pin

        connect_legacy(client_info: client_info, protocol_version: protocol_version, capabilities: capabilities)
      end

      def leave_modern_mode
        @modern_protocol_version = nil
        @modern_client_info = nil
        @modern_capabilities = nil
      end

      # Bounds the probe read when the caller configured no `read_timeout`, and only for the probe:
      # regular requests keep the unbounded default so long-running tools are unaffected.
      # The timeout surfaces as a `RequestHandlerError`, which `connect_auto` treats as legacy evidence
      # and falls back on.
      def with_probe_read_timeout
        return yield if @read_timeout

        @read_timeout = DEFAULT_DISCOVER_PROBE_TIMEOUT
        begin
          yield
        ensure
          @read_timeout = nil
        end
      end

      def probe_discover
        request = {
          jsonrpc: JsonRpcHandler::Version::V2_0,
          id: SecureRandom.uuid,
          method: MCP::Methods::SERVER_DISCOVER,
        }

        @write_mutex.synchronize { write_message(stamp_modern(request)) }
        response = read_response(request)

        if response.key?("error")
          error = response["error"]
          raise RequestHandlerError.new(
            "Server discovery failed: #{error["message"]}",
            { method: MCP::Methods::SERVER_DISCOVER },
            error_type: :internal_error,
          )
        end

        result = response["result"]
        unless result.is_a?(Hash)
          raise RequestHandlerError.new(
            "Server discovery failed: missing result in response",
            { method: MCP::Methods::SERVER_DISCOVER },
            error_type: :internal_error,
          )
        end

        result
      end

      # Modern requests (never notifications, whose `_meta` has no envelope) carry the SEP-2575 triple.
      def stamp_modern(request)
        return request unless modern? && (request[:id] || request["id"])

        ModernEnvelope.stamp(
          request,
          protocol_version: @modern_protocol_version,
          client_info: @modern_client_info,
          capabilities: @modern_capabilities,
        )
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
