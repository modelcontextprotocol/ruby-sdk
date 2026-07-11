# frozen_string_literal: true

require "json"
require_relative "../../transport"

# This file is autoloaded only when `StreamableHTTPTransport` is referenced,
# so the `rack` dependency does not affect `StdioTransport` users.
begin
  require "rack"
rescue LoadError
  raise LoadError, "The 'rack' gem is required to use the StreamableHTTPTransport. " \
    "Add it to your Gemfile: gem 'rack'"
end

module MCP
  class Server
    module Transports
      class StreamableHTTPTransport < Transport
        class InvalidJsonError < StandardError; end

        SSE_HEADERS = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
        }.freeze

        # Secure defaults for stateful mode. Without a finite idle timeout, sessions live until an explicit client DELETE,
        # so an unauthenticated `initialize` flood retains unbounded `ServerSession` objects until memory is exhausted.
        # These defaults expire idle sessions and cap the concurrent count, like the C# SDK (the only reference SDK that
        # hardens this by default, with a 2h idle timeout and a 10k idle-session count). One difference: at the cap this transport
        # rejects a new `initialize` with 503 (after reclaiming any already-expired slots), whereas the C# SDK evicts
        # the oldest idle session. Rejecting keeps established sessions stable and avoids evicting a legitimate idle session on
        # an attacker's behalf, at the cost of refusing new sessions while genuinely full. Pass `session_idle_timeout: nil` to
        # opt out of expiry and `max_sessions: nil` to opt out of the cap.
        DEFAULT_SESSION_IDLE_TIMEOUT = 1800
        DEFAULT_MAX_SESSIONS = 10_000

        # Distinguishes "argument omitted, apply the secure default" from an explicit `nil` (opt out of expiry).
        UNSET_IDLE_TIMEOUT = Object.new.freeze
        private_constant :UNSET_IDLE_TIMEOUT

        # Default upper bound on the JSON-RPC request body. `handle_post` reads the whole
        # body into memory and parses it, so without a cap a single unauthenticated POST
        # can allocate gigabytes and OOM the worker. 4 MiB comfortably
        # fits a typical JSON-RPC request (a 4 MiB JSON string decodes to ~3 MiB of base64
        # payload); raise `max_request_bytes:` for unusually large payloads. Matches the
        # TypeScript SDK's 4 MB default.
        DEFAULT_MAX_REQUEST_BYTES = 4 * 1024 * 1024

        # Conservative bound on JSON nesting depth, so a deeply nested body cannot exhaust
        # the stack or amplify parse cost (complements the byte cap).
        MAX_JSON_NESTING = 64

        # Creates a Streamable HTTP transport that can be mounted as a Rack app.
        #
        # @param server [MCP::Server] the server whose requests this transport dispatches.
        # @param stateless [Boolean] when `true`, no session is issued and each POST is self-contained.
        # @param enable_json_response [Boolean] when `true`, a request is answered with a single JSON
        #   object instead of an SSE stream.
        # @param session_idle_timeout [Numeric, nil] seconds before an idle session is reaped; defaults
        #   to `DEFAULT_SESSION_IDLE_TIMEOUT` (1800) in stateful mode, and an explicit `nil` disables
        #   expiry. Not supported in stateless mode.
        # @param max_sessions [Integer, nil] cap on the concurrent session count in stateful mode; a new
        #   `initialize` past the cap is rejected with HTTP 503, and `nil` disables the cap.
        # @param allowed_origins [Array<String>, nil] extra `Origin` values accepted in addition to
        #   same-origin requests, for DNS rebinding protection.
        # @param allowed_hosts [Array<String>, nil] extra `Host` values accepted beyond the loopback
        #   defaults (`127.0.0.1`, `::1`, `localhost`); each entry matches a bare host name (any port)
        #   or a full `host:port`.
        # @param dns_rebinding_protection [Boolean] when `true` (default), validates the `Host` and
        #   `Origin` headers to prevent DNS rebinding; pass `false` when an upstream proxy already
        #   validates them.
        # @param session_request_validator [#call, nil] An optional
        #   `->(request, session_id) { true | false }` invoked on every non-`initialize` POST, GET, and DELETE
        #   against an existing session (regular requests, notifications, and client responses alike).
        #   Returning a falsy value rejects the request with HTTP 403. The SDK issues a random `SecureRandom.uuid`
        #   session ID and otherwise only checks existence/idle-timeout, so binding a session to a user is
        #   the deploying application's responsibility (the transport never receives the authenticated identity
        #   on its own); this is the seam to enforce ownership and mitigate session poisoning. Without a validator,
        #   ownership is not enforced.
        # @param max_request_bytes [Integer] upper bound in bytes on a POST request body; larger
        #   requests are rejected with HTTP 413. Defaults to 4 MiB.
        def initialize(
          server,
          stateless: false,
          enable_json_response: false,
          session_idle_timeout: UNSET_IDLE_TIMEOUT,
          max_sessions: DEFAULT_MAX_SESSIONS,
          allowed_origins: nil,
          allowed_hosts: nil,
          dns_rebinding_protection: true,
          session_request_validator: nil,
          max_request_bytes: DEFAULT_MAX_REQUEST_BYTES
        )
          super(server)
          # Maps `session_id` to `{ get_sse_stream: stream_object, server_session: ServerSession, last_active_at: float_from_monotonic_clock, origin: origin_header }`.
          @sessions = {}
          @mutex = Mutex.new

          @stateless = stateless
          @enable_json_response = enable_json_response
          @session_request_validator = session_request_validator
          @dns_rebinding_protection = dns_rebinding_protection

          # Host names are case-insensitive, so the allow lists are compared down-cased.
          @allowed_hosts = (DEFAULT_LOOPBACK_HOSTS + Array(allowed_hosts)).map(&:downcase).freeze
          @allowed_origins = Array(allowed_origins).map(&:downcase).freeze
          @pending_responses = {}

          # Resolve the idle timeout: an explicit value (including `nil` to opt out) wins; otherwise apply the secure default,
          # which does not apply to stateless mode since it retains no sessions.
          @session_idle_timeout = if session_idle_timeout.equal?(UNSET_IDLE_TIMEOUT)
            stateless ? nil : DEFAULT_SESSION_IDLE_TIMEOUT
          else
            session_idle_timeout
          end

          if @session_idle_timeout
            if @stateless
              raise ArgumentError, "session_idle_timeout is not supported in stateless mode."
            elsif @session_idle_timeout <= 0
              raise ArgumentError, "session_idle_timeout must be a positive number."
            end
          end

          unless max_sessions.nil? || (max_sessions.is_a?(Integer) && max_sessions > 0)
            raise ArgumentError, "max_sessions must be a positive Integer or nil"
          end

          # The cap guards the stateful session store; stateless mode keeps none.
          @max_sessions = stateless ? nil : max_sessions

          unless max_request_bytes.is_a?(Integer) && max_request_bytes > 0
            raise ArgumentError, "max_request_bytes must be a positive Integer"
          end

          @max_request_bytes = max_request_bytes

          start_reaper_thread if @session_idle_timeout
        end

        REQUIRED_POST_ACCEPT_TYPES_SSE = ["application/json", "text/event-stream"].freeze
        REQUIRED_POST_ACCEPT_TYPES_JSON = ["application/json"].freeze
        REQUIRED_GET_ACCEPT_TYPES = ["text/event-stream"].freeze
        STREAM_WRITE_ERRORS = [IOError, Errno::EPIPE, Errno::ECONNRESET].freeze
        SESSION_REAP_INTERVAL = 60

        # Loopback hosts always accepted by DNS rebinding protection. A locally bound MCP server (the canonical pattern) is
        # protected out of the box; non-loopback deployments widen the list via `allowed_hosts:`.
        DEFAULT_LOOPBACK_HOSTS = ["127.0.0.1", "::1", "localhost"].freeze

        # Rack app interface. This transport can be mounted as a Rack app.
        def call(env)
          handle_request(Rack::Request.new(env))
        end

        def handle_request(request)
          rebinding_error = validate_dns_rebinding(request)
          return rebinding_error if rebinding_error

          case request.env["REQUEST_METHOD"]
          when "POST"
            handle_post(request)
          when "GET"
            handle_get(request)
          when "DELETE"
            handle_delete(request)
          else
            method_not_allowed_response
          end
        end

        def close
          @reaper_thread&.kill
          @reaper_thread = nil

          removed_sessions = @mutex.synchronize do
            @sessions.each_key.filter_map { |session_id| cleanup_session_unsafe(session_id) }
          end

          removed_sessions.each do |session|
            close_stream_safely(session[:get_sse_stream])
            close_post_request_streams(session)
          end
        end

        def send_notification(method, params = nil, session_id: nil, related_request_id: nil)
          # Stateless mode has no streams to deliver notifications on. Report non-delivery instead of raising
          # so the ephemeral per-request session's notify_* helpers (e.g. progress or log notifications from
          # a tool handler) degrade gracefully rather than spamming the exception reporter on every call.
          return false if @stateless

          notification = {
            jsonrpc: "2.0",
            method: method,
          }
          notification[:params] = params if params

          if session_id
            deliver_targeted_notification(notification, session_id, related_request_id)
          else
            deliver_broadcast_notification(notification)
          end
        end

        def deliver_targeted_notification(notification, session_id, related_request_id)
          # JSON response mode returns a single JSON object as the POST response,
          # so request-scoped notifications (e.g. progress, log) cannot be delivered
          # alongside it. Session-scoped standalone notifications
          # (e.g. `resources/updated`, `elicitation/complete`) still flow via GET SSE.
          return false if @enable_json_response && related_request_id

          streams_to_close = []

          # Resolve the target stream under the lock, then write outside it: a stalled SSE reader
          # must not block every other session that needs `@mutex`.
          stream = @mutex.synchronize do
            next unless (session = @sessions[session_id])

            if session_expired?(session)
              cleanup_and_collect_stream(session_id, streams_to_close)
              next
            end

            active_stream(session, related_request_id: related_request_id)
          end

          close_streams(streams_to_close)
          return false unless stream

          write_notification(stream, notification, session_id, related_request_id)
        end

        def deliver_broadcast_notification(notification)
          streams_to_close = []

          # Snapshot the connected streams under the lock, then write to each outside it.
          targets = @mutex.synchronize do
            expired_session_ids = []

            collected = @sessions.filter_map do |session_id, session|
              next unless (stream = session[:get_sse_stream])

              if session_expired?(session)
                expired_session_ids << session_id
                next
              end

              [session_id, stream]
            end

            expired_session_ids.each do |session_id|
              cleanup_and_collect_stream(session_id, streams_to_close)
            end

            collected
          end

          close_streams(streams_to_close)

          targets.count do |session_id, stream|
            write_notification(stream, notification, session_id, nil)
          end
        end

        # Writes a notification to an SSE stream without holding `@mutex`. On a write error,
        # drops the broken stream and returns false; on success returns true.
        def write_notification(stream, notification, session_id, related_request_id)
          send_to_stream(stream, notification)
          true
        rescue *STREAM_WRITE_ERRORS => e
          MCP.configuration.exception_reporter.call(e, { session_id: session_id, error: "Failed to send notification" })
          drop_broken_stream(session_id, stream, related_request_id)
          false
        end

        # Removes a stream that failed to accept a write. A request-scoped stream is dropped on its own;
        # a session-scoped (GET SSE) failure tears down the whole session. The `@sessions` mutation runs
        # under `@mutex`, and the affected streams are closed outside it.
        def drop_broken_stream(session_id, stream, related_request_id)
          streams_to_close = []

          @mutex.synchronize do
            session = @sessions[session_id]
            if related_request_id && session&.dig(:post_request_streams, related_request_id)
              session[:post_request_streams].delete(related_request_id)
              streams_to_close << stream
            else
              cleanup_and_collect_stream(session_id, streams_to_close)
            end
          end

          close_streams(streams_to_close)
        end

        def close_streams(streams)
          streams.each do |stream|
            close_stream_safely(stream)
          end
        end

        # Sends a server-to-client JSON-RPC request (e.g., `sampling/createMessage`) and
        # blocks until the client responds.
        #
        # Uses a `Queue` for cross-thread synchronization. This method creates a `Queue`,
        # sends the request via SSE stream, then blocks on `queue.pop`.
        # When the client POSTs a response, `handle_response` matches it by `request_id`
        # and pushes the result onto the queue, unblocking this thread.
        def send_request(method, params = nil, session_id: nil, related_request_id: nil, parent_cancellation: nil, server_session: nil)
          if @stateless
            raise "Stateless mode does not support server-to-client requests."
          end

          if @enable_json_response
            raise "JSON response mode does not support server-to-client requests."
          end

          unless session_id
            raise "session_id is required for server-to-client requests."
          end

          request_id = generate_request_id
          queue = Queue.new
          cancel_hook = nil

          request = { jsonrpc: "2.0", id: request_id, method: method }
          request[:params] = params if params

          # Register the pending response and resolve the stream under the lock, but perform
          # the write outside it so a stalled reader cannot block every other session on `@mutex`.
          stream = @mutex.synchronize do
            unless (session = @sessions[session_id])
              raise "Session not found: #{session_id}."
            end

            @pending_responses[request_id] = { queue: queue, session_id: session_id }

            active_stream(session, related_request_id: related_request_id)
          end

          sent = false
          if stream
            begin
              send_to_stream(stream, request)
              sent = true
            rescue *STREAM_WRITE_ERRORS
              drop_broken_stream(session_id, stream, related_request_id)
            end
          end

          # TODO: Replace with event store + replay when resumability is implemented.
          # Resumability is a separate MCP specification feature (SSE event IDs, Last-Event-ID replay,
          # event store management) independent of sampling.
          # See: https://modelcontextprotocol.io/specification/latest/basic/transports#resumability-and-redelivery
          #
          # The TypeScript and Python SDKs buffer messages and replay on reconnect.
          # Until then, raise to prevent queue.pop from blocking indefinitely.
          unless sent
            raise "No active stream for #{method} request."
          end

          if parent_cancellation && server_session
            cancel_hook = parent_cancellation.on_cancel do |reason|
              server_session.send_peer_cancellation(
                nested_request_id: request_id,
                related_request_id: related_request_id,
                reason: reason,
              )
            end
          end

          response = queue.pop

          if response.is_a?(Hash) && response.key?(:error)
            raise StandardError, "Client returned an error for #{method} request (code: #{response[:error][:code]}): #{response[:error][:message]}"
          end

          if response == :session_closed
            raise "SSE session closed while waiting for #{method} response."
          end

          if response == :cancelled
            reason = @mutex.synchronize { @pending_responses.dig(request_id, :cancel_reason) }
            raise MCP::CancelledError.new(
              "#{method} request was cancelled",
              request_id: request_id,
              reason: reason,
            )
          end

          response
        ensure
          parent_cancellation.off_cancel(cancel_hook) if cancel_hook
          if request_id
            @mutex.synchronize do
              @pending_responses.delete(request_id)
            end
          end
        end

        # Unblocks a `send_request` awaiting a response when the peer is being cancelled.
        # The waiting thread will see `:cancelled` on its queue and raise `MCP::CancelledError`.
        #
        # Race note: this is first-writer-wins on the pending-response queue. If a real response
        # has already been pushed (client responded before the cancel hook fired), that response
        # wins and `:cancelled` is enqueued behind it but never read - `send_request` returns
        # the real response and deletes the pending entry in its `ensure` block. Conversely,
        # if `:cancelled` arrives first, any later client response is silently dropped in `handle_response`
        # because the pending entry has been removed.
        def cancel_pending_request(request_id, reason: nil)
          @mutex.synchronize do
            if (pending = @pending_responses[request_id])
              pending[:cancel_reason] = reason
              pending[:queue].push(:cancelled)
            end
          end
        end

        private

        def start_reaper_thread
          @reaper_thread = Thread.new do
            loop do
              sleep(SESSION_REAP_INTERVAL)
              reap_expired_sessions
            rescue StandardError => e
              MCP.configuration.exception_reporter.call(e, error: "Session reaper error")
            end
          end
        end

        def reap_expired_sessions
          return unless @session_idle_timeout

          removed_sessions = @mutex.synchronize do
            @sessions.each_key.filter_map do |session_id|
              next unless session_expired?(@sessions[session_id])

              cleanup_session_unsafe(session_id)
            end
          end

          removed_sessions.each do |session|
            close_stream_safely(session[:get_sse_stream])
            close_post_request_streams(session)
          end
        end

        def send_to_stream(stream, data)
          message = data.is_a?(String) ? data : data.to_json
          stream.write("data: #{message}\n\n")
          stream.flush
        end

        def send_ping_to_stream(stream)
          stream.write(": ping #{Time.now.iso8601}\n\n")
          stream.flush
        end

        def handle_post(request)
          required_types = @enable_json_response ? REQUIRED_POST_ACCEPT_TYPES_JSON : REQUIRED_POST_ACCEPT_TYPES_SSE
          accept_error = validate_accept_header(request, required_types)
          return accept_error if accept_error

          content_type_error = validate_content_type(request)
          return content_type_error if content_type_error

          body_string = read_bounded_body(request)
          return payload_too_large_response if body_string.nil?

          session_id = extract_session_id(request)

          begin
            body = parse_request_body(body_string)
          rescue InvalidJsonError
            return invalid_json_response
          end

          # Streamable HTTP (2025-11-25) requires a single JSON-RPC message object per POST.
          # Batched/array bodies are not supported; reject with `-32600` instead of falling through to
          # a malformed Rack response.
          unless body.is_a?(Hash)
            return invalid_request_response("Invalid Request: JSON-RPC body must be a single request object")
          end

          # The `MCP-Protocol-Version` header is only meaningful after negotiation, so on `initialize`
          # the JSON-RPC body `params.protocolVersion` is authoritative and the header (if any) is ignored.
          # This matches the TypeScript and Python SDKs.
          # `server/discover` (SEP-2575) is likewise exempt: it is sessionless capability discovery that
          # happens before (or instead of) negotiation.
          unless initialize_request?(body) || discover_request?(body)
            return missing_session_id_response if !@stateless && !session_id

            protocol_version_error = validate_protocol_version_header(request)
            return protocol_version_error if protocol_version_error
          end

          if initialize_request?(body)
            if !@stateless && session_id
              # An `initialize` request carrying an `Mcp-Session-Id` header is either a duplicate
              # initialization attempt against a live session, or a retry against an unknown/expired
              # one. In the live case, reject with `-32600` so the original session is not abandoned.
              # In the unknown/expired case, return 404 so the client retries from scratch instead
              # of silently inheriting a fresh session under the old ID.
              return already_initialized_response(body[:id]) if session_active?(session_id)

              return session_not_found_response
            end

            handle_initialization(request, body_string, body)
          else
            # Ownership gate for every request against an existing session, applied uniformly to notifications, client responses,
            # and regular requests. This covers write paths beyond tool calls - notably `notifications/cancelled`, which would
            # otherwise let a stolen session ID cancel a victim's in-flight request. `initialize` is exempt (it establishes the session).
            if !@stateless && session_id && !validate_session_request(request, session_id)
              return forbidden_response
            end

            if notification?(body)
              dispatch_notification(body_string, session_id)
              handle_accepted
            elsif response?(body)
              return session_not_found_response if !@stateless && !session_exists?(session_id)

              handle_response(body, session_id: session_id)
            else
              handle_regular_request(body_string, session_id, related_request_id: body[:id])
            end
          end
        rescue StandardError => e
          MCP.configuration.exception_reporter.call(e, { request: body_string })
          json_rpc_error_response(
            status: 500,
            code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            message: "Internal server error",
          )
        end

        def handle_get(request)
          if @stateless
            return method_not_allowed_response
          end

          accept_error = validate_accept_header(request, REQUIRED_GET_ACCEPT_TYPES)
          return accept_error if accept_error

          session_id = extract_session_id(request)

          return missing_session_id_response unless session_id

          error_response = validate_and_touch_session(session_id)
          return error_response if error_response
          return forbidden_response unless validate_session_request(request, session_id)

          protocol_version_error = validate_protocol_version_header(request)
          return protocol_version_error if protocol_version_error

          return session_already_connected_response if get_session_stream(session_id)

          setup_sse_stream(session_id)
        end

        def handle_delete(request)
          success_response = [200, { "Content-Type" => "application/json" }, [{ success: true }.to_json]]

          if @stateless
            protocol_version_error = validate_protocol_version_header(request)
            return protocol_version_error if protocol_version_error

            # Stateless mode doesn't support sessions, so we can just return a success response
            return success_response
          end

          return missing_session_id_response unless (session_id = extract_session_id(request))
          return session_not_found_response unless session_exists?(session_id)
          return forbidden_response unless validate_session_request(request, session_id)

          protocol_version_error = validate_protocol_version_header(request)
          return protocol_version_error if protocol_version_error

          cleanup_session(session_id)

          success_response
        end

        def cleanup_session(session_id)
          session = @mutex.synchronize do
            cleanup_session_unsafe(session_id)
          end

          if session
            close_stream_safely(session[:get_sse_stream])
            close_post_request_streams(session)
          end
        end

        # Removes a session from `@sessions` and returns it. Does not close the stream.
        # Callers must close the stream outside the mutex to avoid holding the lock during
        # potentially blocking I/O.
        def cleanup_session_unsafe(session_id)
          session = @sessions.delete(session_id)

          # Unblock threads waiting on pending responses for this session.
          @pending_responses.each_value do |pending_response|
            if pending_response[:session_id] == session_id
              pending_response[:queue].push(:session_closed)
            end
          end

          session
        end

        def cleanup_and_collect_stream(session_id, streams_to_close)
          return unless (removed = cleanup_session_unsafe(session_id))

          streams_to_close << removed[:get_sse_stream]
          removed[:post_request_streams]&.each_value { |stream| streams_to_close << stream }
        end

        def close_stream_safely(stream)
          stream&.close
        rescue StandardError
          # Ignore close-related errors from already closed/broken streams.
        end

        def close_post_request_streams(session)
          return unless (post_request_streams = session[:post_request_streams])

          post_request_streams.each_value do |stream|
            close_stream_safely(stream)
          end
        end

        def extract_session_id(request)
          request.env["HTTP_MCP_SESSION_ID"]
        end

        # Session-ownership gate for requests against an existing session (the spec's session-binding guidance).
        # The session ID alone is unguessable but not proof of ownership, so a stolen ID must not silently grant access.
        # Two layers, both returning `false` to trigger a 403:
        #
        # - Built-in Origin consistency (defense in depth, not authentication): if the session recorded an `Origin`
        #   at `initialize` and this request carries a different one, reject. Both must be present to compare,
        #   so non-browser clients that send no `Origin` are unaffected.
        # - The application-supplied `session_request_validator`, which can enforce true ownership when it has
        #   an authenticated principal.
        def validate_session_request(request, session_id)
          session = @mutex.synchronize { @sessions[session_id] }
          return true unless session

          session_origin = session[:origin]
          request_origin = request.env["HTTP_ORIGIN"]
          return false if session_origin && request_origin && session_origin != request_origin
          return @session_request_validator.call(request, session_id) if @session_request_validator

          true
        end

        def validate_accept_header(request, required_types)
          accept_header = request.env["HTTP_ACCEPT"]
          return not_acceptable_response(required_types) unless accept_header

          accepted_types = parse_accept_header(accept_header)
          return if accepted_types.include?("*/*")

          missing_types = required_types - accepted_types
          return not_acceptable_response(required_types) unless missing_types.empty?

          nil
        end

        def parse_accept_header(header)
          header.split(",").map do |part|
            part.split(";").first.strip.downcase
          end
        end

        def validate_content_type(request)
          content_type = request.env["CONTENT_TYPE"]
          media_type = content_type&.split(";")&.first&.strip&.downcase
          return if media_type == "application/json"

          json_rpc_error_response(
            status: 415,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Unsupported Media Type: Content-Type must be application/json",
          )
        end

        def not_acceptable_response(required_types)
          json_rpc_error_response(
            status: 406,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Not Acceptable: Accept header must include #{required_types.join(" and ")}",
          )
        end

        # Reads the request body with a hard byte cap so an unbounded POST cannot exhaust
        # memory. A declared `Content-Length` over the cap is rejected
        # without reading; the actual read is also bounded to one byte past the cap, so
        # a missing or spoofed `Content-Length` (e.g. chunked transfer) is still caught.
        # Returns `nil` when the body exceeds the cap.
        def read_bounded_body(request)
          content_length = request.content_length
          return if content_length && content_length.to_i > @max_request_bytes

          body = request.body.read(@max_request_bytes + 1)
          return "" if body.nil?
          return if body.bytesize > @max_request_bytes

          body
        end

        def payload_too_large_response
          json_rpc_error_response(
            status: 413,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Payload too large: request body exceeds #{@max_request_bytes} bytes",
          )
        end

        def parse_request_body(body_string)
          # `max_nesting` bounds parse depth; a too-deep body raises `JSON::NestingError`,
          # a subclass of `JSON::ParserError`, so it is caught below as a parse error.
          JSON.parse(body_string, symbolize_names: true, max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, TypeError
          raise InvalidJsonError
        end

        def invalid_json_response
          json_rpc_error_response(
            status: 400,
            code: JsonRpcHandler::ErrorCode::PARSE_ERROR,
            message: "Parse error: Invalid JSON",
          )
        end

        def initialize_request?(body)
          body.is_a?(Hash) && body[:method] == Methods::INITIALIZE
        end

        def discover_request?(body)
          body.is_a?(Hash) && body[:method] == Methods::SERVER_DISCOVER
        end

        def validate_protocol_version_header(request)
          header_value = request.env["HTTP_MCP_PROTOCOL_VERSION"] || MCP::Configuration::DEFAULT_NEGOTIATED_PROTOCOL_VERSION
          return if MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(header_value)

          supported = MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.join(", ")
          json_rpc_error_response(
            status: 400,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Bad Request: Unsupported protocol version: #{header_value}. Supported versions: #{supported}",
          )
        end

        def json_rpc_error_response(status:, code:, message:)
          body = { jsonrpc: "2.0", id: nil, error: { code: code, message: message } }
          [status, { "Content-Type" => "application/json" }, [body.to_json]]
        end

        def notification?(body)
          !body[:id] && !!body[:method]
        end

        # Dispatches a client-originated notification (e.g. `notifications/cancelled`,
        # `notifications/initialized`) through the server so it can update session state.
        def dispatch_notification(body_string, session_id)
          server_session = nil
          if @stateless
            server_session = ephemeral_session
          elsif session_id
            @mutex.synchronize do
              session = @sessions[session_id]
              server_session = session[:server_session] if session
            end
          end

          dispatch_handle_json(body_string, server_session)
        rescue => e
          MCP.configuration.exception_reporter.call(e, { error: "Failed to dispatch notification" })
        end

        def response?(body)
          !!body[:id] && !body[:method]
        end

        # Verifies that the response came from the expected session to prevent
        # cross-session response injection if request IDs are ever leaked.
        def handle_response(body, session_id:)
          request_id = body[:id]
          @mutex.synchronize do
            if (pending_response = @pending_responses[request_id]) && pending_response[:session_id] == session_id
              if body.key?(:error)
                error = body[:error]
                pending_response[:queue].push(error: { code: error[:code], message: error[:message] })
              else
                pending_response[:queue].push(body[:result])
              end
            end
          end

          handle_accepted
        end

        def handle_initialization(request, body_string, body)
          session_id = nil

          if @stateless
            server_session = ephemeral_session
          else
            session_id = SecureRandom.uuid
            server_session = ServerSession.new(server: @server, transport: self, session_id: session_id)

            # Cap the concurrent session count so an `initialize` flood cannot retain unbounded sessions until memory is exhausted.
            # The check and insert share the mutex so concurrent initializes cannot race past the limit.
            reclaimed = []
            inserted = @mutex.synchronize do
              # When at the cap, first reclaim slots held by already-expired sessions the 60s reaper has not yet collected,
              # so the cap rejects only when genuinely full rather than up to a reaper interval after sessions expired.
              if @max_sessions && @sessions.size >= @max_sessions
                @sessions.each_key.select { |id| session_expired?(@sessions[id]) }.each do |id|
                  cleanup_and_collect_stream(id, reclaimed)
                end
              end

              next false if @max_sessions && @sessions.size >= @max_sessions

              @sessions[session_id] = {
                get_sse_stream: nil,
                server_session: server_session,
                last_active_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
                # Captured for the built-in Origin-consistency defense in `validate_session_request`.
                # Not authentication.
                origin: request.env["HTTP_ORIGIN"],
              }
              true
            end

            reclaimed.each { |stream| close_stream_safely(stream) }
            return too_many_sessions_response unless inserted
          end

          response = server_session.handle_json(body_string)

          # If `Server#init` produced an error response (e.g., malformed JSON-RPC envelope),
          # `mark_initialized!` was never called. Discard the orphaned session and omit
          # the `Mcp-Session-Id` header so the client retries from a clean state instead of
          # reusing a never-initialized ID that would later look like a duplicate `initialize`.
          if session_id && !server_session.initialized?
            cleanup_session(session_id)
            session_id = nil
          end

          headers = {
            "Content-Type" => "application/json",
          }

          headers["Mcp-Session-Id"] = session_id if session_id

          [200, headers, [response]]
        end

        def handle_accepted
          [202, {}, []]
        end

        def too_many_sessions_response
          json_rpc_error_response(
            status: 503,
            code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            message: "Service unavailable: maximum concurrent sessions (#{@max_sessions}) reached",
          )
        end

        def handle_regular_request(body_string, session_id, related_request_id: nil)
          server_session = nil

          if @stateless
            server_session = ephemeral_session
          elsif session_id
            error_response = validate_and_touch_session(session_id)
            return error_response if error_response

            @mutex.synchronize do
              session = @sessions[session_id]
              server_session = session[:server_session] if session
            end
          end

          if session_id && !@stateless && !@enable_json_response
            handle_request_with_sse_response(body_string, session_id, server_session, related_request_id: related_request_id)
          else
            response = dispatch_handle_json(body_string, server_session)

            # `Server#handle_json` returns `nil` when cancellation has suppressed the JSON-RPC response per spec.
            # Mirror the notification path and ack with 202 instead of returning a 200 with a `nil` Rack body,
            # which would produce an empty body the client cannot parse as JSON.
            return handle_accepted if response.nil?

            [200, { "Content-Type" => "application/json" }, [response]]
          end
        end

        # Returns the POST response as an SSE stream so the server can send
        # JSON-RPC requests and notifications during request processing.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server
        def handle_request_with_sse_response(body_string, session_id, server_session, related_request_id: nil)
          body = proc do |stream|
            @mutex.synchronize do
              session = @sessions[session_id]
              if session && related_request_id
                session[:post_request_streams] ||= {}
                session[:post_request_streams][related_request_id] = stream
              end
            end

            begin
              response = dispatch_handle_json(body_string, server_session)

              send_to_stream(stream, response) if response
            ensure
              if related_request_id
                @mutex.synchronize do
                  session = @sessions[session_id]
                  session[:post_request_streams]&.delete(related_request_id) if session
                end
              end

              begin
                stream.close
              rescue StandardError
                # Ignore close-related errors from already closed/broken streams.
              end
            end
          end

          [200, SSE_HEADERS.dup, body]
        end

        # Returns the SSE stream available for server-to-client messages.
        # When `related_request_id` is given, returns only the POST response
        # stream for that request (no fallback to GET SSE). This prevents
        # request-scoped messages from leaking to the wrong stream.
        # When `related_request_id` is nil, returns the GET SSE stream.
        def active_stream(session, related_request_id: nil)
          if related_request_id
            session.dig(:post_request_streams, related_request_id)
          else
            session[:get_sse_stream]
          end
        end

        def dispatch_handle_json(body_string, server_session)
          if server_session
            server_session.handle_json(body_string)
          else
            @server.handle_json(body_string)
          end
        end

        def validate_and_touch_session(session_id)
          removed = nil

          response = @mutex.synchronize do
            next session_not_found_response unless (session = @sessions[session_id])
            next unless @session_idle_timeout

            if session_expired?(session)
              removed = cleanup_session_unsafe(session_id)
              next session_not_found_response
            end

            session[:last_active_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            nil
          end

          if removed
            close_stream_safely(removed[:get_sse_stream])

            removed[:post_request_streams]&.each_value do |stream|
              close_stream_safely(stream)
            end
          end

          response
        end

        def get_session_stream(session_id)
          @mutex.synchronize { @sessions[session_id]&.fetch(:get_sse_stream, nil) }
        end

        def session_exists?(session_id)
          @mutex.synchronize { @sessions.key?(session_id) }
        end

        # Each stateless POST is self-contained (SEP-2567): handlers run against an ephemeral per-request `ServerSession`
        # so client info, logging level, and initialized state never leak onto the shared `Server` instance or across concurrent requests.
        # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567
        def ephemeral_session
          ServerSession.new(server: @server, transport: self, session_id: nil)
        end

        # Returns true iff a session exists and is not past its idle timeout. Expired sessions
        # are evicted as a side effect so a live request never observes a zombie session that
        # the reaper hasn't yet pruned. Does NOT update `last_active_at`; callers that are
        # rejecting a request must not extend the session's lifetime.
        def session_active?(session_id)
          removed = nil
          active = @mutex.synchronize do
            next false unless (session = @sessions[session_id])

            if session_expired?(session)
              removed = cleanup_session_unsafe(session_id)
              next false
            end

            true
          end

          if removed
            close_stream_safely(removed[:get_sse_stream])
            close_post_request_streams(removed)
          end

          active
        end

        # Per MCP 2025-11-25, servers MUST validate the `Origin` header and SHOULD bind only to localhost
        # to prevent DNS rebinding attacks against locally bound MCP servers. Protection is on by default;
        # pass `dns_rebinding_protection: false` to disable it (e.g. when an upstream proxy or middleware already
        # performs the check). The `Host` header is validated against the loopback defaults plus `allowed_hosts:`,
        # and the `Origin` header, when present, must be same-origin or in `allowed_origins:`.
        def validate_dns_rebinding(request)
          return unless @dns_rebinding_protection

          validate_host(request) || validate_origin(request)
        end

        # Rejects a rebound `Host` (e.g. `evil.example.com` re-pointed at 127.0.0.1).
        # A request without a `Host` header (e.g. HTTP/1.0) is allowed; the rebinding vector this guards against always carries one.
        def validate_host(request)
          host = request.env["HTTP_HOST"]
          return if host.nil?

          # An `allowed_hosts:` entry matches either the bare host name (any port)
          # or the full `host:port` value, so both `"app.example.com"` and
          # `"app.example.com:8443"` can be configured.
          normalized = host.downcase
          return if @allowed_hosts.include?(request_hostname(normalized)) || @allowed_hosts.include?(normalized)

          forbidden_response("Forbidden: Invalid Host header")
        end

        # A request without an `Origin` header (typical for non-browser MCP clients) is allowed. A browser cross-origin request is
        # rejected unless the origin is same-origin or explicitly allow-listed via `allowed_origins:`.
        def validate_origin(request)
          origin = request.env["HTTP_ORIGIN"]
          return if origin.nil?
          return if same_origin?(origin, request)
          return if @allowed_origins.include?(origin.downcase)

          forbidden_response("Forbidden: Invalid Origin header")
        end

        # Extracts the host name from a `Host` header value, stripping any port and IPv6 brackets
        # (`[::1]:8080` becomes `::1`, `127.0.0.1:8080` becomes `127.0.0.1`).
        def request_hostname(host)
          return host[/\A\[([^\]]+)\]/, 1] if host.start_with?("[")

          host.split(":").first
        end

        # Compares the `Origin` authority (host:port) against the request's own `Host`.
        # Scheme is not compared (the `Host` header carries none, and `request.scheme` is unreliable behind proxies),
        # but the `Origin`'s scheme is used to drop a redundant default port (`:80` for http, `:443` for https) from
        # both sides so `http://example.com` matches `Host: example.com:80`. Comparison is case-insensitive.
        def same_origin?(origin, request)
          host = request.env["HTTP_HOST"]
          return false if host.nil?

          normalized = origin.downcase
          default_port = normalized.start_with?("https://") ? ":443" : ":80"
          authority = normalized.sub(%r{\Ahttps?://}, "")

          authority.delete_suffix(default_port) == host.downcase.delete_suffix(default_port)
        end

        def forbidden_response(message = "Forbidden: session request validation failed")
          json_rpc_error_response(
            status: 403,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: message,
          )
        end

        def method_not_allowed_response
          json_rpc_error_response(
            status: 405,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Method not allowed",
          )
        end

        def missing_session_id_response
          json_rpc_error_response(
            status: 400,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Missing session ID",
          )
        end

        def session_not_found_response
          json_rpc_error_response(
            status: 404,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Session not found",
          )
        end

        def already_initialized_response(request_id)
          invalid_request_response("Invalid Request: Server already initialized", request_id: request_id)
        end

        def invalid_request_response(message, request_id: nil)
          body = {
            jsonrpc: "2.0",
            id: request_id,
            error: {
              code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
              message: message,
            },
          }
          [400, { "Content-Type" => "application/json" }, [body.to_json]]
        end

        def session_already_connected_response
          json_rpc_error_response(
            status: 409,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Conflict: Only one SSE stream is allowed per session",
          )
        end

        def setup_sse_stream(session_id)
          body = create_sse_body(session_id)

          [200, SSE_HEADERS.dup, body]
        end

        def create_sse_body(session_id)
          proc do |stream|
            stored = store_stream_for_session(session_id, stream)
            start_keepalive_thread(session_id) if stored
          end
        end

        def store_stream_for_session(session_id, stream)
          @mutex.synchronize do
            session = @sessions[session_id]
            if session && !session[:get_sse_stream]
              session[:get_sse_stream] = stream
            else
              # Either session was removed, or another request already established a stream.
              stream.close
              # `stream.close` may return a truthy value depending on the stream class.
              # Explicitly return nil to guarantee a falsy return for callers.
              nil
            end
          end
        end

        def start_keepalive_thread(session_id)
          Thread.new do
            while session_active_with_stream?(session_id)
              sleep(30)
              send_keepalive_ping(session_id)
            end
          rescue StandardError => e
            MCP.configuration.exception_reporter.call(e, { session_id: session_id })
          ensure
            cleanup_session(session_id)
          end
        end

        def session_active_with_stream?(session_id)
          @mutex.synchronize { @sessions.key?(session_id) && @sessions[session_id][:get_sse_stream] }
        end

        def send_keepalive_ping(session_id)
          # Resolve the stream under the lock, then write outside it so a stalled reader
          # cannot block every other session on `@mutex`.
          stream = @mutex.synchronize do
            session = @sessions[session_id]
            session && session[:get_sse_stream]
          end
          return unless stream

          send_ping_to_stream(stream)
        rescue *STREAM_WRITE_ERRORS => e
          MCP.configuration.exception_reporter.call(
            e,
            { session_id: session_id, error: "Stream closed" },
          )
          raise # Re-raise to exit the keepalive loop
        end

        def session_expired?(session)
          return false unless @session_idle_timeout

          Process.clock_gettime(Process::CLOCK_MONOTONIC) - session[:last_active_at] > @session_idle_timeout
        end
      end
    end
  end
end
