# frozen_string_literal: true

require_relative "cancellation"
require_relative "methods"

module MCP
  # Holds per-connection state for a single client session.
  # Created by the transport layer; delegates request handling to the shared `Server`.
  class ServerSession
    attr_reader :session_id, :client, :logging_message_notification

    def initialize(server:, transport:, session_id: nil)
      @server = server
      @transport = transport
      @session_id = session_id
      @client = nil
      @client_capabilities = nil
      @logging_message_notification = nil
      @in_flight = {}
      @in_flight_mutex = Mutex.new
      @initialized = false
    end

    # Whether `initialize` has already completed for this session.
    def initialized?
      @initialized
    end

    # Called by `Server#init` after a successful `initialize` response, so subsequent
    # `initialize` requests on the same session can be rejected per MCP spec
    # (the initialization phase MUST be the first interaction).
    def mark_initialized!
      @initialized = true
    end

    # Registers a `Cancellation` token for an in-flight request.
    def register_in_flight(request_id)
      return if request_id.nil?

      cancellation = Cancellation.new(request_id: request_id)
      @in_flight_mutex.synchronize { @in_flight[request_id] = cancellation }
      cancellation
    end

    def unregister_in_flight(request_id)
      return if request_id.nil?

      @in_flight_mutex.synchronize { @in_flight.delete(request_id) }
    end

    def lookup_in_flight(request_id)
      @in_flight_mutex.synchronize { @in_flight[request_id] }
    end

    # Flips the `Cancellation` for a matching in-flight request received from the peer.
    # Silently ignores unknown IDs per MCP spec (cancellation utilities, item 5).
    def cancel_incoming(request_id:, reason: nil)
      cancellation = lookup_in_flight(request_id)
      cancellation&.cancel(reason: reason)
    end

    # Sends `notifications/cancelled` to the peer for a previously-issued request.
    # Also unblocks any transport-level `send_request` waiting on a response for `request_id`.
    def cancel_request(request_id:, reason: nil)
      params = { requestId: request_id }
      params[:reason] = reason if reason
      send_to_transport(Methods::NOTIFICATIONS_CANCELLED, params)

      if @transport.respond_to?(:cancel_pending_request)
        @transport.cancel_pending_request(request_id, reason: reason)
      end
    rescue => e
      MCP.configuration.exception_reporter.call(e, { notification: "cancelled", request_id: request_id })
    end

    def handle(request)
      @server.handle(request, session: self)
    end

    def handle_json(request_json)
      @server.handle_json(request_json, session: self)
    end

    # Called by `Server#init` during the initialization handshake.
    def store_client_info(client:, capabilities: nil)
      @client = client
      @client_capabilities = capabilities
    end

    # Called by `Server#configure_logging_level`.
    def configure_logging(logging_message_notification)
      @logging_message_notification = logging_message_notification
    end

    # Returns per-session client capabilities, falling back to global.
    def client_capabilities
      @client_capabilities || @server.client_capabilities
    end

    # Sends a `roots/list` request scoped to this session.
    #
    # Per SEP-2260, the request must be associated with an originating client
    # request; prefer `server_context.list_roots` inside a handler, which stamps
    # the association automatically.
    # @deprecated MCP Roots (`roots/list` and
    #   `notifications/roots/list_changed`) is deprecated as of MCP protocol
    #   version 2026-07-28 (SEP-2577). Use tool parameters, resource URIs,
    #   server configuration, or environment variables instead.
    def list_roots(related_request_id: nil)
      warn_unassociated_request(__method__, related_request_id)

      unless client_capabilities&.dig(:roots)
        raise "Client does not support roots."
      end

      send_to_transport_request(Methods::ROOTS_LIST, nil, related_request_id: related_request_id)
    end

    # Sends a `ping` request scoped to this session.
    def ping(related_request_id: nil)
      result = send_to_transport_request(Methods::PING, nil, related_request_id: related_request_id)
      raise Server::ValidationError, "Response validation failed: invalid `result`" unless result.is_a?(Hash)

      result
    end

    # Sends a `sampling/createMessage` request scoped to this session.
    #
    # Per SEP-2260, the request must be associated with an originating client
    # request; prefer `server_context.create_sampling_message` inside a handler,
    # which stamps the association automatically.
    # @deprecated MCP Sampling (`sampling/createMessage`) is deprecated as of
    #   MCP protocol version 2026-07-28 (SEP-2577). Use direct LLM provider
    #   APIs instead.
    def create_sampling_message(related_request_id: nil, **kwargs)
      warn_unassociated_request(__method__, related_request_id)

      params = @server.build_sampling_params(client_capabilities, **kwargs)
      send_to_transport_request(Methods::SAMPLING_CREATE_MESSAGE, params, related_request_id: related_request_id)
    end

    # Sends an `elicitation/create` request (form mode) scoped to this session.
    #
    # Per SEP-2260, the request must be associated with an originating client
    # request; prefer `server_context.create_form_elicitation` inside a handler,
    # which stamps the association automatically.
    def create_form_elicitation(message:, requested_schema:, related_request_id: nil)
      warn_unassociated_request(__method__, related_request_id)

      unless client_capabilities&.dig(:elicitation)
        raise "Client does not support elicitation. " \
          "The client must declare the `elicitation` capability during initialization."
      end

      params = { mode: "form", message: message, requestedSchema: requested_schema }
      send_to_transport_request(Methods::ELICITATION_CREATE, params, related_request_id: related_request_id)
    end

    # Sends an `elicitation/create` request (URL mode) scoped to this session.
    #
    # Per SEP-2260, the request must be associated with an originating client
    # request; prefer `server_context.create_url_elicitation` inside a handler,
    # which stamps the association automatically.
    def create_url_elicitation(message:, url:, elicitation_id:, related_request_id: nil)
      warn_unassociated_request(__method__, related_request_id)

      unless client_capabilities&.dig(:elicitation, :url)
        raise "Client does not support URL mode elicitation. " \
          "The client must declare the `elicitation.url` capability during initialization."
      end

      params = { mode: "url", message: message, url: url, elicitationId: elicitation_id }
      send_to_transport_request(Methods::ELICITATION_CREATE, params, related_request_id: related_request_id)
    end

    # Sends `notifications/cancelled` to the peer for a nested server-to-client request
    # that was started inside a now-cancelled parent request. `related_request_id`
    # is the parent request id so the notification is routed to the same stream
    # (e.g. the parent's POST response stream on `StreamableHTTPTransport`) rather than
    # the GET SSE stream.
    def send_peer_cancellation(nested_request_id:, related_request_id: nil, reason: nil)
      params = { requestId: nested_request_id }
      params[:reason] = reason if reason
      send_to_transport(Methods::NOTIFICATIONS_CANCELLED, params, related_request_id: related_request_id)

      if @transport.respond_to?(:cancel_pending_request)
        @transport.cancel_pending_request(nested_request_id, reason: reason)
      end
    rescue => e
      MCP.configuration.exception_reporter.call(e, { notification: "cancelled", request_id: nested_request_id })
    end

    # Sends an elicitation complete notification scoped to this session.
    def notify_elicitation_complete(elicitation_id:)
      send_to_transport(Methods::NOTIFICATIONS_ELICITATION_COMPLETE, { elicitationId: elicitation_id })
    rescue => e
      @server.report_exception(e, notification: "elicitation_complete")
    end

    # Sends a resource updated notification to this session only.
    def notify_resources_updated(uri:)
      send_to_transport(Methods::NOTIFICATIONS_RESOURCES_UPDATED, { "uri" => uri })
    rescue => e
      @server.report_exception(e, notification: "resources_updated")
    end

    # Sends a progress notification to this session only.
    def notify_progress(progress_token:, progress:, total: nil, message: nil, related_request_id: nil)
      params = {
        "progressToken" => progress_token,
        "progress" => progress,
        "total" => total,
        "message" => message,
      }.compact

      send_to_transport(Methods::NOTIFICATIONS_PROGRESS, params, related_request_id: related_request_id)
    rescue => e
      @server.report_exception(e, notification: "progress")
    end

    # Sends a log message notification to this session only.
    # @deprecated MCP Logging (`logging/setLevel` and `notifications/message`)
    #   is deprecated as of MCP protocol version 2026-07-28 (SEP-2577).
    #   Use stderr or OpenTelemetry instead.
    def notify_log_message(data:, level:, logger: nil, related_request_id: nil)
      effective_logging = @logging_message_notification || @server.logging_message_notification
      return unless effective_logging&.should_notify?(level)

      params = { "data" => data, "level" => level }
      params["logger"] = logger if logger

      send_to_transport(Methods::NOTIFICATIONS_MESSAGE, params, related_request_id: related_request_id)
    rescue => e
      @server.report_exception(e, { notification: "log_message" })
    end

    private

    # Forwards `send_notification` to the transport with only the kwargs the transport's method signature
    # actually accepts. Custom transports that implement the abstract `send_notification(method, params = nil)`
    # contract continue to work unchanged; bundled transports that declare `session_id:` / `related_request_id:`
    # receive the session-scoped routing information.
    def send_to_transport(method, params, related_request_id: nil)
      kwargs = {
        session_id: @session_id,
        related_request_id: related_request_id,
      }.compact

      forward_to_transport(@transport.method(:send_notification), method, params, kwargs)
    end

    # Forwards `send_request` to the transport with only the kwargs the transport's method signature
    # actually accepts. Custom transports that implement the abstract `send_request(method, params = nil)`
    # contract continue to work; bundled transports that declare `session_id:` / `related_request_id:` /
    # `parent_cancellation:` / `server_session:` receive the nested-cancellation plumbing.
    # When `related_request_id` names an in-flight request, its `Cancellation` token is looked up
    # so that cancelling the parent also cancels this nested server-to-client request.
    def send_to_transport_request(method, params, related_request_id: nil)
      parent_cancellation = related_request_id ? lookup_in_flight(related_request_id) : nil

      kwargs = {
        session_id: @session_id,
        related_request_id: related_request_id,
        parent_cancellation: parent_cancellation,
        server_session: self,
      }.compact

      forward_to_transport(@transport.method(:send_request), method, params, kwargs)
    end

    # Calls `transport_method(method, params, **supported)` where `supported` contains only the keys
    # the transport's method signature accepts. This keeps bundled transports (which declare the new kwargs)
    # working while preserving compatibility with custom transports that implement only the abstract
    # `(method, params = nil)` contract.
    def forward_to_transport(transport_method, method, params, kwargs)
      parameters = transport_method.parameters
      accepts_keyrest = parameters.any? { |type, _| type == :keyrest }
      supported = if accepts_keyrest
        kwargs
      else
        allowed = parameters.filter_map { |type, name| name if type == :key || type == :keyreq }
        kwargs.slice(*allowed)
      end

      # Always splat `**supported` even when empty: on Ruby 2.7 the bare `transport_method.call(method, params)`
      # form would let the trailing `params` Hash be auto-promoted to keyword arguments when the receiver
      # accepts `**kwargs`, breaking handlers that rely on `params` arriving as a positional Hash.
      # The explicit splat suppresses that conversion and is a no-op when `supported` is empty.
      transport_method.call(method, params, **supported)
    end

    # Per SEP-2260, servers MUST send `roots/list`, `sampling/createMessage`, and `elicitation/create` only
    # in association with an originating client request (`ping` is exempt). A request without `related_request_id:` is
    # delivered on the standalone GET stream by the Streamable HTTP transport, which the 2026-07-28 spec forbids;
    # warn so callers migrate to the `server_context` helpers before this becomes an error.
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2260
    def warn_unassociated_request(method_name, related_request_id)
      return if related_request_id

      warn(
        "Calling `ServerSession##{method_name}` without `related_request_id:` is deprecated (SEP-2260): " \
          "server-to-client #{method_name} requests must be associated with an originating client request. " \
          "Use `server_context.#{method_name}` inside a handler, or pass `related_request_id:` explicitly.",
        uplevel: 2,
      )
    end
  end
end
