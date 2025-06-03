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
          raise NotImplementedError, "#{self.class.name}#parse_body is not implemented"
        end

        # Parses a request object query parameters into a hash of parameters.
        #
        # @param request [Object] The request object to parse
        # @return [Hash] The parsed params
        def parse_query_params(request)
          raise NotImplementedError, "#{self.class.name}#parse_query_params is not implemented"
        end

        # Checks whether the request is using the GET method
        #
        # @param request [Object] The request object to parse
        # @return [Boolean] true when the request is using the GET method, false otherwise
        def get?(request)
          raise NotImplementedError, "#{self.class.name}#get? is not implemented"
        end
      end
    end
  end
end
