# frozen_string_literal: true

# require "json_rpc_handler"
# require_relative "shared/instrumentation"
# require_relative "shared/methods"

module MCP
  module Client
    # Can be made an abstract class if we need shared behavior

    class RequestHandlerError < StandardError
      attr_reader :error_type, :original_error, :request

      def initialize(message, request, error_type: :internal_error, original_error: nil)
        super(message)
        @request = request
        @error_type = error_type
        @original_error = original_error
      end
    end
  end
end
