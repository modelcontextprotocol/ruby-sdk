# frozen_string_literal: true

module MCP
  class CancelledError < StandardError
    attr_reader :request_id, :reason

    def initialize(message = "Request was cancelled", request_id: nil, reason: nil)
      super(message)
      @request_id = request_id
      @reason = reason
    end
  end
end
