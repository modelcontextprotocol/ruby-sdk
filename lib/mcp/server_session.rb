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
      @client_capabilities = nil # TODO: Use for per-session capability validation.
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

    # Sends a progress notification to this session only.
    def notify_progress(progress_token:, progress:, total: nil, message: nil)
      params = {
        "progressToken" => progress_token,
        "progress" => progress,
        "total" => total,
        "message" => message,
      }.compact

      send_to_transport(Methods::NOTIFICATIONS_PROGRESS, params)
    rescue => e
      @server.report_exception(e, notification: "progress")
    end

    # Sends a log message notification to this session only.
    def notify_log_message(data:, level:, logger: nil)
      effective_logging = @logging_message_notification || @server.logging_message_notification
      return unless effective_logging&.should_notify?(level)

      params = { "data" => data, "level" => level }
      params["logger"] = logger if logger

      send_to_transport(Methods::NOTIFICATIONS_MESSAGE, params)
    rescue => e
      @server.report_exception(e, { notification: "log_message" })
    end

    private

    # TODO: When Ruby 2.7 support is dropped, replace with a direct call:
    # `@transport.send_notification(method, params, session_id: @session_id)` and
    # add `**` to `Transport#send_notification` and `StdioTransport#send_notification`.
    def send_to_transport(method, params)
      if @session_id
        @transport.send_notification(method, params, session_id: @session_id)
      else
        @transport.send_notification(method, params)
      end
    end
  end
end
