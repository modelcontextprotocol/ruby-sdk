# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../server/provider"

module MCP
  module Auth
    module Server
      module Handlers
        class CallbackHandler
          def initialize(
            auth_server_provider:,
            request_parser:
          )
            @auth_server_provider = auth_server_provider
            @request_parser = request_parser
          end

          def handle(request)
            params_h = @request_parser.parse_query_params(request)
            code = params_h[:code]
            state = params_h[:state]
            if code.nil? || state.nil?
              return bad_request_error(error: "invalid_request", error_description: "missing code or state parameter")
            end

            begin
              redirect_uri = @auth_server_provider.authorize_callback(code:, state:)
              headers = { Location: redirect_uri }

              [302, headers, nil]
            rescue Errors::AuthorizationError => e
              bad_request_error(
                error: e.error_code,
                error_description: e.message,
              )
            rescue
              [500, {}, { error: "server_error" }]
            end
          end

          private

          def bad_request_error(error:, error_description:)
            [400, {}, { error:, error_description: }]
          end
        end
      end
    end
  end
end
