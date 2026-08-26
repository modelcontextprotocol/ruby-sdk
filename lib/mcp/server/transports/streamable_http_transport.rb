# frozen_string_literal: true

require "json"
require_relative "../../result_type"
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

        # `x-accel-buffering: no` tells reverse proxies (nginx and friends) not to buffer the response,
        # which the spec asks of every SSE stream: a buffering proxy holds events back instead of
        # delivering them as they are written, and on a long-lived `subscriptions/listen` stream that
        # also swallows the keepalive frames a dropped peer would otherwise be detected by.
        # The TypeScript and Python SDKs send it on their SSE responses for the same reason.
        SSE_HEADERS = {
          "content-type" => "text/event-stream",
          "cache-control" => "no-cache",
          "connection" => "keep-alive",
          "x-accel-buffering" => "no",
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

        # Cap on concurrent `subscriptions/listen` streams (SEP-2575). Each stream holds an open SSE connection
        # for its lifetime, so without a bound an unauthenticated client can retain unbounded connections,
        # like the session-flood case `DEFAULT_MAX_SESSIONS` guards. A listen request past the cap is rejected with HTTP 503;
        # pass `max_listen_subscriptions: nil` to opt out.
        DEFAULT_MAX_LISTEN_SUBSCRIPTIONS = 1_000

        # Distinguishes "argument omitted, apply the secure default" from an explicit `nil` (opt out of expiry).
        UNSET_IDLE_TIMEOUT = Object.new.freeze
        private_constant :UNSET_IDLE_TIMEOUT

        # Default deadline in seconds for a server-to-client request (sampling, elicitation, `roots/list`, `ping`).
        # The spec asks implementations to bound every sent request so a peer that never answers cannot exhaust
        # the sender's resources; without one, a client that opens a session and simply never replies parks
        # a worker thread for good.
        #
        # Ten minutes matches the TypeScript SDK, which raises its uniform 60-second request default to 600 seconds
        # for the legs of its legacy `input_required` shim because they are "human-paced, so the 60s protocol default
        # is wrong". Every request this transport can send is that kind of leg: someone answering an elicitation
        # prompt, or the client's own model producing a sample. (The Python SDK leaves the deadline unset and bounds
        # nothing by default.) Deployments that want a tighter bound pass a smaller value here; a single handler
        # that legitimately waits longer passes `timeout:`.
        #
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#timeouts
        DEFAULT_SERVER_TO_CLIENT_REQUEST_TIMEOUT = 600

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

        # Cap on the notifications buffered for one modern request (SEP-2575). The sink holds them
        # in memory until the handler returns, so a handler that emits notifications in proportion to
        # client-supplied input would otherwise let one request grow memory without bound.
        # Notifications past the cap are not delivered and the notify helpers report `false`,
        # the same non-delivery degradation they have on every other undeliverable path.
        MAX_MODERN_REQUEST_NOTIFICATIONS = 1_000

        # Interval in seconds between SSE keepalive comment frames on a `subscriptions/listen` stream.
        # Without them a silently dropped connection holds its slot until the next fan-out write fails,
        # so on a quiet server a dead peer would occupy a `max_listen_subscriptions` slot indefinitely.
        # The periodic write detects the dead peer and frees the slot. Matches the TypeScript SDK's
        # 15-second default; pass `listen_keepalive_interval: nil` when an upstream proxy pings the stream.
        DEFAULT_LISTEN_KEEPALIVE_INTERVAL = 15

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
        # @param max_listen_subscriptions [Integer, nil] cap on concurrent `subscriptions/listen`
        #   streams; a listen request past the cap is rejected with HTTP 503, and `nil` disables
        #   the cap.
        # @param listen_keepalive_interval [Numeric, nil] seconds between SSE keepalive comment frames
        #   on a `subscriptions/listen` stream; the periodic write frees the stream's slot when the peer
        #   has gone away. Defaults to `DEFAULT_LISTEN_KEEPALIVE_INTERVAL` (15); pass `nil` to disable
        #   when an upstream proxy already keeps the stream alive.
        # @param serve_subscriptions_listen [Boolean] whether `subscriptions/listen` opens a stream.
        #   A host that buffers responses and cannot serve an open SSE stream (e.g. the Rails controller pattern,
        #   which builds a fresh transport per request and renders the body) passes `false`:
        #   the method then answers 404 with JSON-RPC `-32601` like any unimplemented method,
        #   and `Server#discover` stops advertising the `listChanged`/`subscribe` capability flags,
        #   keeping the advertisement and the actual behavior in agreement. Defaults to `true`.
        # @param server_to_client_request_timeout [Numeric] seconds a server-to-client request waits for its
        #   response before the transport stops waiting and raises `MCP::Server::RequestTimeoutError`.
        #   Defaults to `DEFAULT_SERVER_TO_CLIENT_REQUEST_TIMEOUT` (600); individual calls override it with `timeout:`.
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
          max_request_bytes: DEFAULT_MAX_REQUEST_BYTES,
          max_listen_subscriptions: DEFAULT_MAX_LISTEN_SUBSCRIPTIONS,
          listen_keepalive_interval: DEFAULT_LISTEN_KEEPALIVE_INTERVAL,
          serve_subscriptions_listen: true,
          server_to_client_request_timeout: DEFAULT_SERVER_TO_CLIENT_REQUEST_TIMEOUT
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

          # Maps a `subscriptions/listen` request id to
          # `{ stream: stream_object, filter: honored_subscription_filter, active: boolean, write_mutex: Mutex }` (SEP-2575).
          # In-process only; a multi-worker deployment needs an external event bus to fan notifications out across processes,
          # which is a follow-up.
          @listen_subscriptions = {}

          # Maps a modern request's ephemeral session id to the Array collecting the notifications its handler emits;
          # `handle_modern` registers the sink and flushes it as SSE frames ahead of the final response (SEP-2575).
          @modern_request_sinks = {}

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

          if !max_listen_subscriptions.nil? && !(max_listen_subscriptions.is_a?(Integer) && max_listen_subscriptions > 0)
            raise ArgumentError, "max_listen_subscriptions must be a positive Integer or nil"
          end

          @max_listen_subscriptions = max_listen_subscriptions

          if !listen_keepalive_interval.nil? && !(listen_keepalive_interval.is_a?(Numeric) && listen_keepalive_interval > 0)
            raise ArgumentError, "listen_keepalive_interval must be a positive number or nil"
          end

          @listen_keepalive_interval = listen_keepalive_interval
          @serve_subscriptions_listen = serve_subscriptions_listen

          unless server_to_client_request_timeout.is_a?(Numeric) && server_to_client_request_timeout.positive?
            raise ArgumentError, "server_to_client_request_timeout must be a positive number"
          end

          @server_to_client_request_timeout = server_to_client_request_timeout

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

        # JSON-RPC methods whose target name is mirrored into the `Mcp-Name` header (SEP-2575).
        NAME_BEARING_METHODS = [Methods::TOOLS_CALL, Methods::RESOURCES_READ, Methods::PROMPTS_GET].freeze

        # Maps broadcast notification methods to the `SubscriptionFilter` field that opts in to them on
        # a `subscriptions/listen` stream (SEP-2575). `notifications/resources/updated` is matched by URI
        # against `resourceSubscriptions` instead.
        LISTEN_FILTER_FIELDS = {
          Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED => :toolsListChanged,
          Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED => :promptsListChanged,
          Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED => :resourcesListChanged,
        }.freeze

        # JSON-RPC error codes that surface as HTTP 400 on the modern path. `-32601` maps to 404
        # (disambiguating an unknown method from a legacy HTTP+SSE 404) and everything else, including internal errors,
        # stays 200, matching the Python SDK's status ladder.
        MODERN_BAD_REQUEST_CODES = [
          ErrorCodes::HEADER_MISMATCH,
          ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
          ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
          JsonRpcHandler::ErrorCode::PARSE_ERROR,
          JsonRpcHandler::ErrorCode::INVALID_REQUEST,
          JsonRpcHandler::ErrorCode::INVALID_PARAMS,
        ].freeze

        # Rack app interface. This transport can be mounted as a Rack app.
        def call(env)
          handle_request(Rack::Request.new(env))
        end

        # Whether this transport serves the `subscriptions/listen` notification stream (SEP-2575).
        # Gates both the route (a refusing transport answers the method as unimplemented) and
        # the `listChanged`/`subscribe` capability flags `Server#discover` advertises,
        # so the two always agree. Set via the `serve_subscriptions_listen:` constructor keyword.
        def serves_subscriptions_listen?
          @serve_subscriptions_listen
        end

        def handle_request(request)
          rebinding_error = validate_dns_rebinding(request)
          return rebinding_error if rebinding_error

          # Header-primary era routing (SEP-2575). An `MCP-Protocol-Version` header naming a version outside
          # every supported list routes to the sessionless modern path, so an unknown future version receives
          # the spec-mandated `-32022` with the supported list instead of the legacy path's generic invalid-request error.
          # Requests without the header, or with a stable-only version, take the existing paths untouched.
          # An empty header value is malformed rather than a version claim, so it stays on the legacy path
          # and fails legacy header validation as before.
          #
          # A modern header value (2026-07-28) alone cannot decide the era: sessionless modern traffic carries it,
          # and requests of an established legacy session may stamp it as well (the handshake itself never negotiates it):
          # an `Mcp-Session-Id` binds the request to an established legacy session (POST requests, the GET SSE stream,
          # and DELETE termination keep working), and a session-less POST whose body is `initialize` is
          # the legacy-distinctive handshake. Everything else under a dual-era header is sessionless modern traffic
          # (`server/discover`, envelope-carrying requests, and envelope-missing requests that get the modern path's error shape).
          header_version = request.env["HTTP_MCP_PROTOCOL_VERSION"]
          if header_version && !header_version.empty? && !stable_only_version?(header_version)
            unless MCP::Configuration.modern_protocol_version?(header_version)
              return handle_modern(request, header_version)
            end

            if extract_session_id(request).nil?
              return handle_modern(request, header_version) unless request.env["REQUEST_METHOD"] == "POST"

              # The body is readable only once (Rack 3 inputs need not be rewindable), so the era sniff reads it here,
              # bounded, and hands the string to whichever path serves the request.
              body_string = read_bounded_body(request)
              return payload_too_large_response if body_string.nil?

              unless legacy_handshake_body?(body_string)
                return handle_modern(request, header_version, body_string: body_string)
              end

              return handle_post(request, body_string: body_string)
            end
          end

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

          teardown_listen_subscriptions

          removed_sessions = @mutex.synchronize do
            @sessions.each_key.filter_map { |session_id| cleanup_session_unsafe(session_id) }
          end

          removed_sessions.each do |session|
            close_stream_safely(session[:get_sse_stream])
            close_post_request_streams(session)
          end
        end

        def send_notification(method, params = nil, session_id: nil, related_request_id: nil)
          # `subscriptions/listen` streams (SEP-2575) receive matching change notifications regardless of the delivery below:
          # a resource updated by one session's tool call changed globally, so modern subscribers hear about it too.
          # Runs before the per-request sink and the stateless guard because the listen registry does not depend on sessions,
          # and a sink capturing the notification for its own response stream must not hide it from other subscriptions.
          deliver_to_listen_subscriptions(method, params)

          notification = {
            jsonrpc: "2.0",
            method: method,
          }
          notification[:params] = params if params

          # A modern request's notifications ride its own response stream (SEP-2575): `handle_modern` registers
          # a per-request sink for its ephemeral session and flushes it as SSE frames ahead of the final response.
          # Checked before the stateless guard, since modern requests are served in stateless deployments too.
          # The sink is bounded; past `MAX_MODERN_REQUEST_NOTIFICATIONS` the notification is dropped as
          # non-delivery (`false`), never handed to the legacy paths below.
          sink = @mutex.synchronize { session_id && @modern_request_sinks[session_id] }
          if sink
            return false if sink.size >= MAX_MODERN_REQUEST_NOTIFICATIONS

            sink << notification
            return true
          end

          # Stateless mode has no streams to deliver notifications on. Report non-delivery instead of raising
          # so the ephemeral per-request session's notify_* helpers (e.g. progress or log notifications from
          # a tool handler) degrade gracefully rather than spamming the exception reporter on every call.
          return false if @stateless

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
            if related_request_id
              # Unregister only our own stream: removing on the id alone would drop whichever stream currently holds it,
              # which is not necessarily the one that failed. The failed stream is closed either way, and a request-scoped
              # failure never reaches the session teardown below.
              registered = session&.dig(:post_request_streams, related_request_id)
              session[:post_request_streams].delete(related_request_id) if registered.equal?(stream)

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

        # Sends a server-to-client JSON-RPC request (e.g., `sampling/createMessage`) and blocks until
        # the client responds.
        #
        # Uses a `PendingResponse` for cross-thread synchronization: this method registers one,
        # sends the request via SSE stream, then waits on it. When the client POSTs a response,
        # `handle_response` matches it by `request_id` and resolves the pending response,
        # unblocking this thread. A cancellation and session teardown resolve it the same way.
        #
        # The wait is bounded by `timeout` (defaulting to the transport's `server_to_client_request_timeout`),
        # so a client that never answers cannot park the calling thread for good. On expiry the peer is
        # sent `notifications/cancelled` and `MCP::Server::RequestTimeoutError` is raised.
        def send_request(method, params = nil, session_id: nil, related_request_id: nil, parent_cancellation: nil, server_session: nil, timeout: nil)
          # The modern lifecycle (SEP-2575) forbids server-initiated JSON-RPC requests;
          # multi round-trip `input_required` results (SEP-2322) replace them. A modern session has never reached
          # the rest of this method anyway, since `handle_modern` mints its session without registering it in `@sessions`,
          # but that is incidental: without the rule stated here a modern handler that reaches for elicitation
          # or sampling is told "Session not found: <uuid>", which points at everything except the actual reason.
          # `StdioTransport#send_request` refuses the same way.
          if server_session&.era == :modern
            raise "Server-initiated requests are not available in the modern lifecycle (SEP-2575)."
          end

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
          pending_response = PendingResponse.new
          wait_timeout = timeout || @server_to_client_request_timeout
          cancel_hook = nil

          request = { jsonrpc: "2.0", id: request_id, method: method }
          request[:params] = params if params

          # Register the pending response and resolve the stream under the lock, but perform
          # the write outside it so a stalled reader cannot block every other session on `@mutex`.
          stream = @mutex.synchronize do
            unless (session = @sessions[session_id])
              raise "Session not found: #{session_id}."
            end

            @pending_responses[request_id] = { queue: pending_response, session_id: session_id }

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

          response = pending_response.pop(timeout: wait_timeout) do
            # Expiry cancels as well as stops waiting, so a client that answers late does not act on
            # a request the server has abandoned. Only connections speaking 2025-11-25 or earlier get here:
            # the modern lifecycle forbids server-to-client requests outright, and its sessionless requests
            # never register the session this method looks up. Those revisions ask the sender to "issue
            # a cancellation notification for that request and stop waiting", letting either side send one.
            # (The 2026-07-28 rule reserving `notifications/cancelled` for `subscriptions/listen` teardown
            # governs the era that has no such requests to cancel.) Both reference SDKs send this same
            # courtesy cancel on timeout.
            server_session&.send_peer_cancellation(
              nested_request_id: request_id,
              related_request_id: related_request_id,
              reason: "Timed out after #{wait_timeout} seconds",
            )

            raise RequestTimeoutError.new(
              "#{method} request timed out after #{wait_timeout} seconds",
              request_id: request_id,
              timeout: wait_timeout,
            )
          end

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

        # Serves one request of the stateless modern lifecycle (MCP 2026-07-28, SEP-2575):
        # a single POST/JSON exchange with no session. The modern path never consults
        # `@stateless`, `@sessions`, or `@enable_json_response`, and never issues or accepts
        # an `Mcp-Session-Id`. GET (the legacy listening stream, replaced by `subscriptions/listen`)
        # and DELETE (session termination) have no modern meaning.
        def handle_modern(request, header_version, body_string: nil)
          return method_not_allowed_response unless request.env["REQUEST_METHOD"] == "POST"

          accept_error = validate_accept_header(request, REQUIRED_POST_ACCEPT_TYPES_SSE)
          return accept_error if accept_error

          content_type_error = validate_content_type(request)
          return content_type_error if content_type_error

          if body_string.nil?
            body_string = read_bounded_body(request)
            return payload_too_large_response if body_string.nil?
          end

          begin
            body = parse_request_body(body_string)
          rescue InvalidJsonError
            return invalid_json_response
          end

          unless body.is_a?(Hash)
            return invalid_request_response("Invalid Request: JSON-RPC body must be a single request object")
          end

          # The version check precedes everything else that depends on request content,
          # so a client probing with an unknown future version always receives the `-32022` signal
          # (with the supported list to select from) rather than an incidental error.
          unless MCP::Configuration.modern_protocol_version?(header_version)
            return json_rpc_error_response(
              status: 400,
              code: ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
              message: "Unsupported protocol version",
              data: {
                supported: MCP::Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS,
                requested: header_version,
              },
              id: body[:id],
            )
          end

          if extract_session_id(request)
            return json_rpc_error_response(
              status: 400,
              code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
              message: "Bad Request: Mcp-Session-Id is not accepted in the modern lifecycle",
              id: body[:id],
            )
          end

          mismatch_error = validate_modern_headers(request, body, header_version)
          return mismatch_error if mismatch_error

          # `subscriptions/listen` is a long-lived notification stream served at the transport layer;
          # it never dispatches through `Server#handle`. A transport constructed with
          # `serve_subscriptions_listen: false` skips the interception, so the method falls through
          # to the dispatcher as unimplemented (404 with `-32601`) - the refusal a host that cannot
          # serve an open SSE stream needs, instead of a `Proc` body it can never call.
          if body[:method] == Methods::SUBSCRIPTIONS_LISTEN && serves_subscriptions_listen?
            return handle_subscriptions_listen(body)
          end

          session = modern_session
          notifications = @mutex.synchronize { @modern_request_sinks[session.session_id] = [] }
          begin
            response = @server.handle(body, session: session)
          ensure
            @mutex.synchronize { @modern_request_sinks.delete(session.session_id) }
          end

          # `nil` covers notifications and cancellation-suppressed responses; ack with 202 like the legacy notification path.
          return handle_accepted if response.nil?

          # Notifications a handler emitted during the request ride the request's own response stream as SSE frames ahead of
          # the final response (SEP-2575); a request that emitted none keeps the single JSON exchange and its HTTP status ladder.
          # Delivery is buffered: frames flush after the handler returns, preserving order but not real-time interleaving
          # (the TypeScript and Python SDKs stream live), and the sink grows with the handler's notification count.
          # Live streaming can follow without changing the wire shape.
          if notifications.empty?
            [modern_http_status(response), { "content-type" => "application/json" }, [response.to_json]]
          else
            frames = notifications + [response]
            sse_body = frames.map { |frame| "event: message\ndata: #{frame.to_json}\n\n" }.join
            [200, SSE_HEADERS.dup, [sse_body]]
          end
        rescue StandardError => e
          MCP.configuration.exception_reporter.call(e, { request: body_string })
          json_rpc_error_response(
            status: 500,
            code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            message: "Internal server error",
          )
        end

        # Enforces the SEP-2575 header/body match rules (`-32020`, HTTP 400): the `MCP-Protocol-Version` header
        # MUST match the `_meta`-carried version, and the `Mcp-Method` / `Mcp-Name` mirror headers MUST match
        # the body when sent. Absent mirror headers are tolerated for interoperability while other SDK serving stacks
        # converge on enforcement.
        def validate_modern_headers(request, body, header_version)
          params = body[:params]
          meta_version = params.is_a?(Hash) ? params.dig(:_meta, :"io.modelcontextprotocol/protocolVersion") : nil
          if meta_version && meta_version != header_version
            return header_mismatch_response(
              "MCP-Protocol-Version header value '#{header_version}' does not match body value '#{meta_version}'",
              body[:id],
            )
          end

          # `Mcp-Method` is required on every modern POST and `Mcp-Name` on the name-bearing methods:
          # the spec lists a missing required standard header among the validation failures that MUST be rejected,
          # and the TypeScript SDK enforces presence the same way. Absence cannot be treated as "nothing to compare":
          # the headers exist so intermediaries can route without parsing bodies, and a client that omits them
          # defeats that contract silently.
          method_header = request.env["HTTP_MCP_METHOD"]
          if method_header.to_s.empty?
            return header_mismatch_response(
              "Mcp-Method header is required on the modern path",
              body[:id],
            )
          end
          if method_header != body[:method]
            return header_mismatch_response(
              "Mcp-Method header value '#{method_header}' does not match body value '#{body[:method]}'",
              body[:id],
            )
          end

          if NAME_BEARING_METHODS.include?(body[:method])
            body_name = params.is_a?(Hash) ? params[:name] || params[:uri] : nil
            name_header = request.env["HTTP_MCP_NAME"]
            if body_name
              if name_header.to_s.empty?
                return header_mismatch_response(
                  "Mcp-Name header is required for `#{body[:method]}`",
                  body[:id],
                )
              end

              decoded_name = decode_header_value(name_header)
              if decoded_name != body_name
                return header_mismatch_response(
                  "Mcp-Name header value '#{decoded_name}' does not match body value '#{body_name}'",
                  body[:id],
                )
              end
            end
          end

          nil
        end

        # Serves `subscriptions/listen` (SEP-2575): opens a long-lived SSE stream whose first message is
        # `notifications/subscriptions/acknowledged` with the subset of requested notification types
        # the server agreed to honor. Notifications delivered on the stream carry `io.modelcontextprotocol/subscriptionId`
        # (= the listen request id) in `_meta`. A graceful teardown (transport `close`) sends a `SubscriptionsListenResult`
        # response; an abrupt disconnect sends nothing. A keepalive comment frame is written every
        # `listen_keepalive_interval` seconds so a dropped connection frees its slot.
        def handle_subscriptions_listen(body)
          request_id = body[:id]
          params = body[:params]

          # A listen frame without an id could never receive stream teardown correlation.
          unless request_id
            return invalid_request_response("Invalid Request: subscriptions/listen requires an id")
          end

          begin
            if RequestEnvelope.modern?(params)
              RequestEnvelope.parse!(params, request: params)
            else
              return invalid_request_response("Invalid Request: modern requests require the SEP-2575 `_meta` envelope")
            end
          rescue Server::RequestHandlerError => e
            return json_rpc_error_response(
              status: 400,
              code: e.error_code || JsonRpcHandler::ErrorCode::INVALID_REQUEST,
              message: e.message,
              data: e.error_data,
              id: request_id,
            )
          end

          filter = params[:notifications]
          unless filter.is_a?(Hash)
            return json_rpc_error_response(
              status: 400,
              code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
              message: "Invalid params: subscriptions/listen requires a `notifications` filter object",
              id: request_id,
            )
          end

          # Best-effort cap check before committing to the SSE response; the registration inside
          # `listen_sse_body` re-checks atomically for the race between two concurrent listens
          # crossing the cap together.
          if listen_subscriptions_full?
            return too_many_listen_subscriptions_response(request_id)
          end

          [200, SSE_HEADERS.dup, listen_sse_body(request_id, honored_filter(filter))]
        end

        def listen_subscriptions_full?
          return false unless @max_listen_subscriptions

          @mutex.synchronize { @listen_subscriptions.size >= @max_listen_subscriptions }
        end

        def too_many_listen_subscriptions_response(request_id)
          json_rpc_error_response(
            status: 503,
            code: JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            message: "Service unavailable: maximum concurrent subscriptions/listen streams (#{@max_listen_subscriptions}) reached",
            id: request_id,
          )
        end

        # The Rack streaming body of a `subscriptions/listen` response. It responds to `call`
        # and deliberately not to `each`, so Rack keeps classifying it as a streaming body;
        # `first` exists only to turn the buffered-host mistake (e.g. `render(json: body.first)`
        # in the Rails controller pattern) from a bare `NoMethodError` into guidance naming the fix.
        class ListenStreamBody
          def initialize(&block)
            @block = block
          end

          def call(stream)
            @block.call(stream)
          end

          def first
            raise <<~MESSAGE
              subscriptions/listen returned a streaming SSE body, which cannot be buffered into a JSON response. \
              A host that cannot hold an SSE response open should construct the transport with `serve_subscriptions_listen: false`, \
              so the method is answered as unimplemented instead.
              See the Rails (controller) section at https://ruby.sdk.modelcontextprotocol.io/server/transports/ for the hosting patterns.
            MESSAGE
          end
        end
        private_constant :ListenStreamBody

        # The body registers the stream and returns, leaving the response open like
        # the legacy GET stream (`create_sse_body`).
        #
        # Registration and activation are split on purpose: the entry is inserted inactive
        # (reserving the id and the cap slot atomically), the acknowledgement is written outside the lock,
        # and only then does the entry become eligible for delivery. A concurrent notification between
        # the insert and the acknowledgement write skips the inactive entry,
        # enforcing the SEP-2575 rule that no notification precedes the acknowledgement.
        def listen_sse_body(request_id, honored)
          ListenStreamBody.new do |stream|
            rejected = false
            @mutex.synchronize do
              if @listen_subscriptions.key?(request_id) ||
                  (@max_listen_subscriptions && @listen_subscriptions.size >= @max_listen_subscriptions)
                rejected = true
              else
                @listen_subscriptions[request_id] = { stream: stream, filter: honored, active: false, write_mutex: Mutex.new }
              end
            end

            if rejected
              close_stream_safely(stream)
            else
              acknowledgement = {
                jsonrpc: "2.0",
                method: Methods::NOTIFICATIONS_SUBSCRIPTIONS_ACKNOWLEDGED,
                params: {
                  notifications: honored,
                  _meta: { RequestEnvelope::SUBSCRIPTION_ID_META_KEY.to_sym => request_id },
                },
              }

              begin
                send_to_stream(stream, acknowledgement)
                activate_listen_subscription(request_id)
                start_listen_keepalive_thread(request_id)
              rescue *STREAM_WRITE_ERRORS
                remove_listen_subscription(request_id)
                close_stream_safely(stream)
              end
            end
          end
        end

        # Marks a listen subscription eligible for delivery once its acknowledgement write has completed.
        # The entry may already be gone when the transport closed concurrently.
        def activate_listen_subscription(request_id)
          @mutex.synchronize do
            subscription = @listen_subscriptions[request_id]
            subscription[:active] = true if subscription
          end
        end

        # Periodically writes an SSE keepalive comment frame to a listen stream so a silently dropped
        # connection is detected and its slot freed, rather than held until the next fan-out write.
        # Mirrors the legacy GET stream's `start_keepalive_thread`; a comment frame (not a data frame)
        # cannot corrupt an interleaved notification's JSON.
        def start_listen_keepalive_thread(request_id)
          return unless @listen_keepalive_interval

          Thread.new do
            while listen_subscription_active?(request_id)
              sleep(@listen_keepalive_interval)
              send_listen_keepalive_ping(request_id)
            end
          rescue *STREAM_WRITE_ERRORS
            # The peer went away; the ensure frees the slot. A dropped listen stream is the normal
            # way this loop ends, so it is not reported.
          rescue StandardError => e
            MCP.configuration.exception_reporter.call(e, { subscription_id: request_id })
          ensure
            stream = @mutex.synchronize do
              subscription = @listen_subscriptions.delete(request_id)
              subscription && subscription[:stream]
            end
            close_stream_safely(stream) if stream
          end
        end

        def listen_subscription_active?(request_id)
          @mutex.synchronize { @listen_subscriptions.key?(request_id) }
        end

        # Resolves the stream under the lock, then writes outside it so a stalled reader cannot block
        # every other subscription on `@mutex`. A write error propagates to end the keepalive loop.
        def send_listen_keepalive_ping(request_id)
          stream = @mutex.synchronize do
            subscription = @listen_subscriptions[request_id]
            subscription && subscription[:stream]
          end
          return unless stream

          send_ping_to_stream(stream)
        end

        # Per SEP-2575, the server MUST NOT send notification types the client has not requested,
        # and the acknowledgement only includes types the server actually supports
        # (derived from its declared capabilities).
        def honored_filter(filter)
          capabilities = @server.capabilities
          honored = {}
          honored[:toolsListChanged] = true if filter[:toolsListChanged] && capability_flag?(capabilities, :tools, :listChanged)
          honored[:promptsListChanged] = true if filter[:promptsListChanged] && capability_flag?(capabilities, :prompts, :listChanged)
          honored[:resourcesListChanged] = true if filter[:resourcesListChanged] && capability_flag?(capabilities, :resources, :listChanged)

          subscriptions = filter[:resourceSubscriptions]
          if capability_flag?(capabilities, :resources, :subscribe) && subscriptions.is_a?(Array) && !subscriptions.empty?
            honored[:resourceSubscriptions] = subscriptions
          end

          honored
        end

        # Reads a nested capability flag tolerating both symbol and string keys, since user-supplied capability hashes arrive
        # in either form. The flag that promises delivery (`listChanged` / `subscribe`) decides honoring, the same derivation
        # `Server#discover` uses for its era-aware capability stripping; the mere presence of the primitive's capability is not enough.
        def capability_flag?(capabilities, name, flag)
          value = capabilities[name] || capabilities[name.to_s]
          return false unless value.is_a?(Hash)

          !!(value[flag] || value[flag.to_s])
        end

        # Fans a notification out to every `subscriptions/listen` stream whose honored filter opted in to it,
        # stamping the correlating `subscriptionId` into `_meta`. Matching against the honored filter
        # (not the requested one) enforces the MUST NOT-send-unrequested-types rule.
        def deliver_to_listen_subscriptions(method, params)
          field = LISTEN_FILTER_FIELDS[method]
          return if field.nil? && method != Methods::NOTIFICATIONS_RESOURCES_UPDATED

          # The matching snapshot is taken under `@mutex`, but stream writes happen outside it:
          # a slow or stalled subscriber must not block the transport, matching the legacy delivery paths.
          matched = @mutex.synchronize do
            @listen_subscriptions.filter_map do |request_id, subscription|
              # An inactive entry has not finished writing its acknowledgement yet;
              # delivering to it would put a notification ahead of the acknowledgement.
              next unless subscription[:active]

              hit = if field
                subscription[:filter][field]
              else
                uris = subscription[:filter][:resourceSubscriptions]
                uri = params.is_a?(Hash) ? params[:uri] || params["uri"] : nil
                uris.is_a?(Array) && uris.include?(uri)
              end

              [request_id, subscription] if hit
            end
          end

          matched.each do |request_id, subscription|
            meta = { RequestEnvelope::SUBSCRIPTION_ID_META_KEY.to_sym => request_id }
            notification_params = (params || {}).merge(_meta: meta)
            notification = { jsonrpc: "2.0", method: method, params: notification_params }

            begin
              # The per-stream write mutex orders this write against a concurrent graceful teardown:
              # once teardown has marked the entry closed and written its `SubscriptionsListenResult`,
              # a delivery that snapshotted the entry before the registry was cleared skips it instead
              # of writing after the final message.
              subscription[:write_mutex].synchronize do
                next if subscription[:closed]

                send_to_stream(subscription[:stream], notification)
              end
            rescue *STREAM_WRITE_ERRORS => e
              MCP.configuration.exception_reporter.call(
                e,
                { subscription_id: request_id, error: "Failed to send notification" },
              )
              remove_listen_subscription(request_id)
              close_stream_safely(subscription[:stream])
            end
          end
        end

        def remove_listen_subscription(request_id)
          @mutex.synchronize { @listen_subscriptions.delete(request_id) }
        end

        # Graceful teardown (SEP-2575): each open listen stream receives its `SubscriptionsListenResult` response
        # before the stream closes.
        def teardown_listen_subscriptions
          removed = @mutex.synchronize do
            subscriptions = @listen_subscriptions.dup
            @listen_subscriptions.clear
            subscriptions
          end

          removed.each do |request_id, subscription|
            # Marking the entry closed and writing the result under the stream's write mutex orders
            # this against in-flight deliveries: each one either lands before the result or observes
            # `closed` and skips, keeping the graceful result the stream's final message.
            subscription[:write_mutex].synchronize do
              subscription[:closed] = true

              begin
                send_to_stream(subscription[:stream], {
                  jsonrpc: "2.0",
                  id: request_id,
                  result: {
                    # `SubscriptionsListenResult` is served at the transport layer and never
                    # passes through the dispatch path, so the REQUIRED 2026-07-28 `resultType` is
                    # stamped at its construction site.
                    resultType: ResultType::COMPLETE,
                    _meta: { RequestEnvelope::SUBSCRIPTION_ID_META_KEY.to_sym => request_id },
                  },
                })
              rescue *STREAM_WRITE_ERRORS
                nil
              end
            end
            close_stream_safely(subscription[:stream])
          end
        end

        def header_mismatch_response(message, id)
          json_rpc_error_response(
            status: 400,
            code: ErrorCodes::HEADER_MISMATCH,
            message: "Header mismatch: #{message}",
            id: id,
          )
        end

        # Mirrors `MCP::Client::HTTP#encode_header_value`: a value wrapped as `=?base64?<base64>?=` decodes to
        # its original UTF-8 string; anything else is taken verbatim. Duplicated here because the client transport
        # requires faraday, which servers do not depend on.
        def decode_header_value(value)
          match = value.match(/\A=\?base64\?(.*)\?=\z/m)
          return value unless match

          match[1].unpack1("m0").force_encoding(Encoding::UTF_8)
        rescue ArgumentError
          value
        end

        # Each modern request is self-contained: handlers run against an ephemeral per-request `ServerSession` locked to
        # the modern era. The session carries a fresh unregistered `session_id` so notification and server-initiated-request plumbing
        # keyed by session lookup degrades gracefully (delivery returns `false`) instead of broadcasting to unrelated legacy sessions
        # via the `session_id.nil?` branch.
        def modern_session
          ServerSession.new(server: @server, transport: self, session_id: SecureRandom.uuid, era: :modern)
        end

        def modern_http_status(response)
          error_code = response.is_a?(Hash) ? response.dig(:error, :code) : nil
          if error_code.nil?
            200
          elsif error_code == JsonRpcHandler::ErrorCode::METHOD_NOT_FOUND
            404
          elsif MODERN_BAD_REQUEST_CODES.include?(error_code)
            400
          else
            200
          end
        end

        def handle_post(request, body_string: nil)
          required_types = @enable_json_response ? REQUIRED_POST_ACCEPT_TYPES_JSON : REQUIRED_POST_ACCEPT_TYPES_SSE
          accept_error = validate_accept_header(request, required_types)
          return accept_error if accept_error

          content_type_error = validate_content_type(request)
          return content_type_error if content_type_error

          if body_string.nil?
            body_string = read_bounded_body(request)
            return payload_too_large_response if body_string.nil?
          end

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

          # Header-primary routing sends sessionless modern traffic to `handle_modern` before this method runs,
          # so a body carrying the modern `_meta` triple (SEP-2575) arrives here in two shapes only.
          # Bound to a session under a dual-era header (2026-07-28), it is a lifecycle violation: the session
          # already negotiated the legacy lifecycle via `initialize`, and a connection can never change eras
          # (mirroring the stdio era lock). Otherwise the header is missing or names a stable-only version,
          # which violates the header/body match requirement and would fall through the legacy path via
          # the header default; reject that as a header mismatch.
          if RequestEnvelope.modern?(body[:params])
            header_version = request.env["HTTP_MCP_PROTOCOL_VERSION"]
            if header_version && MCP::Configuration.modern_protocol_version?(header_version)
              return invalid_request_response(
                "Invalid Request: the session already negotiated the legacy lifecycle via `initialize`",
                request_id: body[:id],
              )
            end

            return header_mismatch_response(
              "MCP-Protocol-Version header is missing or legacy while the body carries the modern _meta envelope",
              body[:id],
            )
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
              # Reject a notification carrying an unknown or expired session ID instead of
              # dispatching it against the shared `Server`. Mirrors the response and regular-request
              # branches; without it a custom notification handler could run without a live session.
              return session_not_found_response if !@stateless && !session_active?(session_id)

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
          success_response = [200, { "content-type" => "application/json" }, [{ success: true }.to_json]]

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

        # A version with no modern meaning, whose header can only accompany legacy traffic.
        # A modern version's header (2026-07-28) can accompany either era's traffic - the handshake never negotiates it,
        # but requests of an established legacy session may stamp it - so that value needs further disambiguation.
        def stable_only_version?(version)
          MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.include?(version) &&
            !MCP::Configuration.modern_protocol_version?(version)
        end

        # Era sniff for a sessionless POST under a dual-era header version: only an `initialize` body
        # WITHOUT the modern `_meta` envelope is legacy-distinctive. An `initialize` carrying
        # the envelope comes from a modern client naming a method its lifecycle removed, so it stays
        # on the modern path and answers with -32601/404 (SEP-2575).
        # Unparsable or non-object bodies go to the modern path, whose error responses cover them.
        def legacy_handshake_body?(body_string)
          body = parse_request_body(body_string)
          return false unless initialize_request?(body)

          !RequestEnvelope.modern?(body[:params])
        rescue InvalidJsonError
          false
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

        def json_rpc_error_response(status:, code:, message:, data: nil, id: nil)
          error = { code: code, message: message }
          error[:data] = data if data
          body = { jsonrpc: "2.0", id: id, error: error }
          [status, { "content-type" => "application/json" }, [body.to_json]]
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

          # `initialize_request?` matches on the method alone, so an `initialize` sent without
          # an id (framed as a notification) reaches here. `Server#init` marks the session initialized,
          # but JSON-RPC emits no response for an id-less request, so `response` is nil.
          # Returning `[200, ..., [nil]]` would place nil in the Rack body (which the web server cannot serialize),
          # and the session would be retained since it is marked initialized. Discard the orphaned session
          # and ack with 202, mirroring the nil-response handling in a regular request.
          if response.nil?
            cleanup_session(session_id) if session_id
            return handle_accepted
          end

          # If `Server#init` produced an error response (e.g., malformed JSON-RPC envelope),
          # `mark_initialized!` was never called. Discard the orphaned session and omit
          # the `Mcp-Session-Id` header so the client retries from a clean state instead of
          # reusing a never-initialized ID that would later look like a duplicate `initialize`.
          if session_id && !server_session.initialized?
            cleanup_session(session_id)
            session_id = nil
          end

          headers = {
            "content-type" => "application/json",
          }

          headers["mcp-session-id"] = session_id if session_id

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

          # `Server` refuses a duplicate id as well, but only once the request reaches it. The SSE branch below
          # registers this request's stream under that id first, so without this check the colliding request
          # would take over the routing entry for the moment it takes to be rejected, and its `ensure` would then
          # clear the entry the original request still needs.
          if related_request_id && server_session&.in_flight?(related_request_id)
            return request_id_conflict_response
          end

          if session_id && !@stateless && !@enable_json_response
            handle_request_with_sse_response(body_string, session_id, server_session, related_request_id: related_request_id)
          else
            response = dispatch_handle_json(body_string, server_session)

            # `Server#handle_json` returns `nil` when cancellation has suppressed the JSON-RPC response per spec.
            # Mirror the notification path and ack with 202 instead of returning a 200 with a `nil` Rack body,
            # which would produce an empty body the client cannot parse as JSON.
            return handle_accepted if response.nil?

            [200, { "content-type" => "application/json" }, [response]]
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

                # Claim the id only while it is free. `handle_regular_request` already refused the colliding request,
                # so reaching an occupied slot means a race got past that check; leaving the first stream in place keeps
                # its messages going where they belong.
                session[:post_request_streams][related_request_id] ||= stream
              end
            end

            begin
              response = dispatch_handle_json(body_string, server_session)

              send_to_stream(stream, response) if response
            ensure
              if related_request_id
                @mutex.synchronize do
                  session = @sessions[session_id]
                  # Only retire our own registration: a request that never claimed the id, or one whose claim has
                  # already been replaced, must not unregister the stream that owns it.
                  registered = session&.dig(:post_request_streams, related_request_id)

                  session[:post_request_streams].delete(related_request_id) if registered.equal?(stream)
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
          [400, { "content-type" => "application/json" }, [body.to_json]]
        end

        def session_already_connected_response
          json_rpc_error_response(
            status: 409,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Conflict: Only one SSE stream is allowed per session",
          )
        end

        # The POST counterpart of the GET conflict above. A request id already in flight cannot be given
        # a stream of its own, because the id is what routes request-scoped messages back.
        def request_id_conflict_response
          json_rpc_error_response(
            status: 409,
            code: JsonRpcHandler::ErrorCode::INVALID_REQUEST,
            message: "Conflict: Request id is already in flight for this session",
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
