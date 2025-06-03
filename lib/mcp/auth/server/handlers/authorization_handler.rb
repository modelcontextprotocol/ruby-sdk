# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../server/provider"

module MCP
  module Auth
    module Server
      module Handlers
        class AuthorizationRequest
          attr_reader :client_id,
            :redirect_uri,
            :code_challenge_method,
            :code_challenge,
            :response_type,
            :state,
            :scope

          def initialize(
            client_id: nil,
            redirect_uri: nil,
            code_challenge_method: nli,
            response_type: nil,
            code_challenge: nil,
            state: nil,
            scope: nil
          )
            if client_id.nil?
              raise Errors::AuthorizationError.invalid_request("client_id must be defined")
            end

            if response_type != "code"
              raise Errors::AuthorizationError.new(
                error_code: Errors::AuthorizationError::UNSUPPORTED_RESPONSE_TYPE,
                message: "response_type must be 'code'",
              )
            end

            if code_challenge_method != "S256"
              raise Errors::AuthorizationError.invalid_request("code_challenge_method must be 'S256'")
            end

            if code_challenge.nil?
              raise Errors::AuthorizationError.invalid_request("code_challenge must be defined")
            end

            @client_id = client_id
            @code_challenge = code_challenge
            @code_challenge_method = code_challenge_method
            @response_type = response_type
            @redirect_uri = redirect_uri
            @state = state
            @scope = scope
          end

          def scopes_array
            return [] if @scope.nil?

            @scope.split(" ")
          end

          def redirect_uri_provided?
            !@redirect_uri.nil?
          end
        end

        class AuthorizationHandler
          def initialize(
            auth_server_provider:,
            request_parser:
          )
            @auth_server_provider = auth_server_provider
            @request_parser = request_parser
          end

          def handle(request)
            # implements authorization requests for grant_type=code;
            # See https://datatracker.ietf.org/doc/html/rfc6749#section-4.1.1
            # For error handling, refer to https://datatracker.ietf.org/doc/html/rfc6749#section-4.1.2.1
            params_h = as_params_h(request) || {}
            client_info, redirect_uri, auth_error = get_client_and_redirect_uri(params_h)
            return bad_request_error(params_h:, auth_error:) if auth_error

            begin
              auth_request = AuthorizationRequest.new(**params_h)
              scopes = auth_request.scopes_array
              client_info.validate_scopes!(scopes)

              auth_params = AuthorizationParams.new(
                client_id: auth_request.client_id,
                state: auth_request.state,
                scopes:,
                code_challenge: auth_request.code_challenge,
                redirect_uri:,
                redirect_uri_provided_explicitly: auth_request.redirect_uri_provided?,
                response_type: auth_request.response_type,
              )
              location = @auth_server_provider.authorize(auth_params)
              headers = {
                "Cache-Control": "no-store",
                "Location": location,
              }
              [302, headers, nil]
            rescue => e
              error_code = case e
              in Errors::InvalidScopeError then Errors::AuthorizationError::INVALID_SCOPE
              in Errors::AuthorizationError then e.error_code
              else
                Errors::AuthorizationError::SERVER_ERROR
              end

              redirect_response_error(
                redirect_uri:,
                error_code:,
                error_description: e.message,
                params_h:,
              )
            end
          end

          private

          def as_params_h(request)
            @request_parser.get?(request) ? @request_parser.parse_query_params(request) : @request_parser.parse_body(request)
          end

          # Validates the client_id and redirect_uri parameters from the authorization request.
          # Returns a tuple of [client_info, redirect_uri, error] where:
          # - client_info is the OAuthClientInformationFull for the client if found and valid
          # - redirect_uri is a string derived from the params and client
          # - error is an AuthorizationError if validation fails, nil otherwise
          #
          # @param params_h [Hash] The authorization request parameters
          # @return [OAuthClientInformationFull, String, AuthorizationError] Tuple of client_info, redirect_uri, error
          def get_client_and_redirect_uri(params_h)
            client_id = params_h[:client_id]
            if client_id.nil?
              return [nil, nil, Errors::AuthorizationError.invalid_request("client_id must be defined")]
            end

            client_info = @auth_server_provider.get_client(client_id)
            if client_info.nil?
              return [nil, nil, Errors::AuthorizationError.invalid_request("client '#{client_id}' not found")]
            end

            redirect_uri = params_h[:redirect_uri]
            if client_info.multiple_redirect_uris? && redirect_uri.nil?
              return [nil, nil, Errors::AuthorizationError.invalid_request("redirect_uri must be defined because client defines multiple options")]
            end

            redirect_uri ||= client_info.redirect_uris.first
            if redirect_uri.nil?
              return [
                nil,
                nil,
                Errors::AuthorizationError.new(
                  error_code: Errors::AuthorizationError::SERVER_ERROR, message: "unable to select a redirect_uri",
                ),
              ]
            end

            unless client_info.valid_redirect_uri?(redirect_uri)
              return [client_info, nil, Errors::AuthorizationError.invalid_request("invalid redirect_uri")]
            end

            [client_info, redirect_uri, nil]
          end

          def redirect_response_error(
            redirect_uri:,
            error_code:,
            error_description:,
            params_h:
          )
          end

          def bad_request_error(
            params_h:,
            auth_error:
          )
            body = { error: auth_error.error_code, error_description: auth_error.message }
            if params_h[:state]
              body[:state] = params_h[:state]
            end

            [400, { "Cache-Control": "no-store" }, body]
          end
        end
      end
    end
  end
end
