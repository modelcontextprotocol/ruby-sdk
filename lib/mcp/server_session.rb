# frozen_string_literal: true

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

    # Sends a `sampling/createMessage` request scoped to this session.
    def create_sampling_message(related_request_id: nil, **kwargs)
      params = @server.build_sampling_params(client_capabilities, **kwargs)
      send_to_transport_request(Methods::SAMPLING_CREATE_MESSAGE, params, related_request_id: related_request_id)
    end

    # Sends an `elicitation/create` request (form mode) scoped to this session.
    def create_form_elicitation(message:, requested_schema:, related_request_id: nil)
      unless client_capabilities&.dig(:elicitation)
        raise "Client does not support elicitation. " \
          "The client must declare the `elicitation` capability during initialization."
      end

      params = { mode: "form", message: message, requestedSchema: requested_schema }
      send_to_transport_request(Methods::ELICITATION_CREATE, params, related_request_id: related_request_id)
    end

    # Sends an `elicitation/create` request (URL mode) scoped to this session.
    def create_url_elicitation(message:, url:, elicitation_id:, related_request_id: nil)
      unless client_capabilities&.dig(:elicitation, :url)
        raise "Client does not support URL mode elicitation. " \
          "The client must declare the `elicitation.url` capability during initialization."
      end

      params = { mode: "url", message: message, url: url, elicitationId: elicitation_id }
      send_to_transport_request(Methods::ELICITATION_CREATE, params, related_request_id: related_request_id)
    end

    # Sends an elicitation complete notification scoped to this session.
    def notify_elicitation_complete(elicitation_id:)
      send_to_transport(Methods::NOTIFICATIONS_ELICITATION_COMPLETE, { elicitationId: elicitation_id })
    rescue => e
      @server.report_exception(e, notification: "elicitation_complete")
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

    # Branches on `@session_id` because `StdioTransport` creates a `ServerSession` without
    # a `session_id` (`session_id: nil`), while `StreamableHTTPTransport` always provides one.
    #
    # TODO: When Ruby 2.7 support is dropped, replace with a direct call:
    # `@transport.send_notification(method, params, session_id: @session_id)` and
    # add `**` to `Transport#send_notification` and `StdioTransport#send_notification`.
    def send_to_transport(method, params, related_request_id: nil)
      if @session_id
        @transport.send_notification(method, params, session_id: @session_id, related_request_id: related_request_id)
      else
        @transport.send_notification(method, params)
      end
    end

    # Branches on `@session_id` because `StdioTransport` creates a `ServerSession` without
    # a `session_id` (`session_id: nil`), while `StreamableHTTPTransport` always provides one.
    #
    # TODO: When Ruby 2.7 support is dropped, replace with a direct call:
    # `@transport.send_request(method, params, session_id: @session_id)` and
    # add `**` to `Transport#send_request` and `StdioTransport#send_request`.
    def send_to_transport_request(method, params, related_request_id: nil)
      if @session_id
        @transport.send_request(method, params, session_id: @session_id, related_request_id: related_request_id)
      else
        @transport.send_request(method, params)
      end
    end
  end
end
