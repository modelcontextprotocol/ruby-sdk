# frozen_string_literal: true

require "digest"
require "base64"
require_relative "../../errors"
require_relative "../../server/provider"
require_relative "../../models"

module MCP
  module Auth
    module Server
      module Handlers
        class BaseRequest
          attr_reader :grant_type, :client_id, :client_secret

          def initialize(
            grant_type:,
            client_id:,
            client_secret: nil
          )
            @grant_type = grant_type
            @client_id = client_id
            @client_secret = client_secret
          end
        end

        class AuthorizationCodeRequest < BaseRequest
          attr_reader :code, :code_verifier, :redirect_uri

          def initialize(
            code:,
            code_verifier:,
            redirect_uri: nil,
            **base_kwargs
          )
            super(**base_kwargs)

            @code = code
            @code_verifier = code_verifier
            @redirect_uri = redirect_uri

            if @grant_type != "authorization_code"
              raise Errors::AuthorizationError.invalid_request("grant_type must be authorization_code")
            end
          end
        end

        class TokenHandler
          def initialize(
            auth_server_provider:,
            request_parser:
          )
            @auth_server_provider = auth_server_provider
            @request_parser = request_parser
          end

          def handle(request)
            params_h = @request_parser.parse_query_params(request)
            request = AuthorizationCodeRequest.new(**params_h)

            client_info = @auth_server_provider.get_client(request.client_id)
            validate_request_client!(request:, client_info:)

            auth_code = @auth_server_provider.load_authorization_code(request.code)
            validate_auth_code!(request:, auth_code:)
            validate_pkce!(request:, auth_code:)
            tokens = @auth_server_provider.exchange_authorization_code(auth_code)

            [200, {}, tokens]
          rescue Errors::ClientAuthenticationError => e
            bad_request_error(
              error_code: Errors::AuthorizationError::UNAUTHORIZED_CLIENT,
              error_description: e.message,
            )
          rescue Errors::AuthorizationError => e
            bad_request_error(
              error_codea: e.error_code,
              error_description: e.message,
            )
          rescue
            bad_request_error(
              error_code: Errors::AuthorizationError::SERVER_ERROR,
              error_description: "unexpected error",
            )
          end

          private

          def validate_request_client!(request:, client_info: nil)
            if client_info.nil?
              raise Errors::AuthorizationError.invalid_request("invalid client_id")
            end

            client_info.authenticate!(
              request_client_id: request.client_id,
              request_client_secret: request.client_secret,
            )
            unless client_info.valid_grant_type?(request.grant_type)
              raise Errors::AuthorizationError.new(
                error_code: Errors::AuthorizationError::UNSUPPORTED_GRANT_TYPE,
                message: "supported grant type are #{client_info.grant_types}",
              )
            end
          end

          def validate_auth_code!(request:, auth_code:)
            if auth_code.nil? || !auth_code.belongs_to_client?(request.client_id)
              # If auth code is for another client, pretend it's not there
              raise Errors::AuthorizationError.invalid_grant("authorization code does not exist")
            end

            if auth_code.expired?
              raise Errors::AuthorizationError.invalid_grant("authorization code expired")
            end

            # verify redirect_uri doesn't change between /authorize and /tokens
            # see https://datatracker.ietf.org/doc/html/rfc6749#section-10.6
            authorize_request_redirect_uri = auth_code.redirect_uri_provided_explicitly ? auth_code.redirect_uri : nil
            if request.redirect_uri != authorize_request_redirect_uri
              raise Errors::AuthorizationError.invalid_request("redirect_uri did not match the one when creating auth code")
            end
          end

          def validate_pkce!(request:, auth_code:)
            sha256 = Digest::SHA256.digest(request.code_verifier.encode)
            request_code_challenge = Base64.urlsafe_encode64(sha256).tr("=", "")

            unless auth_code.code_challenge_match?(request_code_challenge)
              # see https://datatracker.ietf.org/doc/html/rfc7636#section-4.6
              raise Errors::AuthorizationError.invalid_grant("incorrect code_verifier")
            end
          end

          def bad_request_error(
            error_code:,
            error_description:
          )
            body = { error: error_code, error_description: }

            [400, { "Cache-Control": "no-store", "Pragma": "no-cache" }, body]
          end
        end
      end
    end
  end
end
