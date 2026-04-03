# frozen_string_literal: true

require "securerandom"

module MCP
  class Transport
    # Initialize the transport with the server instance
    def initialize(server)
      @server = server
    end

    # Send a response to the client
    def send_response(response)
      raise NotImplementedError, "Subclasses must implement send_response"
    end

    # Open the transport connection
    def open
      raise NotImplementedError, "Subclasses must implement open"
    end

    # Close the transport connection
    def close
      raise NotImplementedError, "Subclasses must implement close"
    end

    # Handle a JSON request
    # Returns a response that should be sent back to the client
    def handle_json_request(request)
      response = @server.handle_json(request)
      send_response(response) if response
    end

    # Handle an incoming request
    # Returns a response that should be sent back to the client
    def handle_request(request)
      response = @server.handle(request)
      send_response(response) if response
    end

    # Send a notification to the client.
    # Returns true if the notification was sent successfully.
    def send_notification(method, params = nil)
      raise NotImplementedError, "Subclasses must implement send_notification"
    end

    # Send a JSON-RPC request to the client and wait for a response.
    def send_request(method, params = nil)
      raise NotImplementedError, "Subclasses must implement send_request"
    end

    private

    def generate_request_id
      SecureRandom.uuid
    end
  end
end
