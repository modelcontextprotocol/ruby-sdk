# frozen_string_literal: true

module ModelContextProtocol
  class Transport
    def initialize(server)
      @server = server
    end

    def send_response(response)
      raise NotImplementedError, "Subclasses must implement send_response"
    end

    def open
      raise NotImplementedError, "Subclasses must implement open"
    end

    def close
      raise NotImplementedError, "Subclasses must implement close"
    end

    private

    def handle_request(request)
      response = @server.handle(request)
      send_response(response) if response
    end

    def handle_json_request(request)
      response = @server.handle_json(request)
      send_response(response) if response
    end
  end
end
