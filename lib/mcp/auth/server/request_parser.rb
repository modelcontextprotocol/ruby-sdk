# frozen_string_literal: true

module MCP
  module Auth
    module Server
      class RequestParser
        # Parses the body of a request object into a hash.
        #
        # @param request [Object] The request object to parse
        # @return [Hash] The parsed body
        def parse_body(request)
          raise NotImplementedError, "Subclass must implement"
        end

        # Parses a request object into a hash of parameters.
        #
        # @param request [Object] The request object to parse
        # @return [Hash] The parsed params
        def parse_request_params(request)
          raise NotImplementedError, "Subclass must implement"
        end
      end
    end
  end
end
