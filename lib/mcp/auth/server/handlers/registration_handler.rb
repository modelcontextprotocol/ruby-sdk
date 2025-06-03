# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "../../../serialization_utils"
require_relative "../../errors"
require_relative "../../models"
require_relative "../settings"

module MCP
  module Auth
    module Server
      module Handlers
        class RegistrationHandler
          include SerializationUtils

          def initialize(
            auth_server_provider:,
            request_parser:
          )
            @auth_server_provider = auth_server_provider
            @client_registration_options = auth_server_provider.client_registration_options
            @request_parser = request_parser
          end

          def handle(request)
            # Implements dynamic client registration as defined in https://datatracker.ietf.org/doc/html/rfc7591#section-3.1
            client_metadata_hash = @request_parser.parse_body(request)
            client_metadata = Models::OAuthClientMetadata.new(**client_metadata_hash)

            client_id_issued_at = Time.now.to_i
            client_info = Models::OAuthClientInformationFull.new(
              client_id:,
              client_id_issued_at:,
              client_secret: client_secret(client_metadata),
              client_secret_expires_at: client_secret_expires_at(client_metadata, client_id_issued_at),
              # passthrough information from the client request
              redirect_uris: client_metadata.redirect_uris,
              token_endpoint_auth_method: client_metadata.token_endpoint_auth_method,
              grant_types: grant_types!(client_metadata),
              response_types: client_metadata.response_types,
              client_name: client_metadata.client_name,
              client_uri: client_metadata.client_uri,
              logo_uri: client_metadata.logo_uri,
              scope: scope!(client_metadata),
              contacts: client_metadata.contacts,
              tos_uri: client_metadata.tos_uri,
              policy_uri: client_metadata.policy_uri,
              jwks_uri: client_metadata.jwks_uri,
              jwks: client_metadata.jwks,
              software_id: client_metadata.software_id,
              software_version: client_metadata.software_version,
            )

            @auth_server_provider.register_client(client_info)

            # See RFC https://datatracker.ietf.org/doc/html/rfc7591#section-3.2.1 for format
            [201, { "Content-Type": "application/json" }, to_h(client_info)]
          rescue Errors::RegistrationError => e
            error_response(
              status: 400,
              error: e.error_code,
              error_description: e.message,
            )
          rescue => e
            error_response(
              status: 400,
              error: Errors::RegistrationError::INVALID_CLIENT_METADATA,
              error_description: e.message,
            )
          end

          private

          def client_id
            SecureRandom.uuid_v4
          end

          def client_secret(client_metadata)
            if client_metadata.token_endpoint_auth_method == "none"
              return
            end

            SecureRandom.hex(32)
          end

          def client_secret_expires_at(client_metadata, issued_at)
            if @client_registration_options.client_secret_expiry_seconds
              issued_at + @client_registration_options.client_secret_expiry_seconds
            end

            nil
          end

          def scope!(client_metadata)
            if client_metadata.scope.nil? && @client_registration_options.default_scopes
              return @client_registration_options.default_scopes.join(" ")
            end

            if client_metadata.scope
              requested_scopes = client_metadata.scope.split
              @client_registration_options.validate_scopes!(requested_scopes)
            end

            client_metadata.scope
          rescue Errors::InvalidScopeError => e
            raise e.message
          end

          def grant_types!(client_metadata)
            @client_registration_options.validate_grant_types!(client_metadata.grant_types || [])

            client_metadata.grant_types
          rescue InvalidGrantsError => e
            raise e.message
          end

          def error_response(status:, error:, error_description:)
            # See RFC https://datatracker.ietf.org/doc/html/rfc7591#section-3.2.2 for format
            headers = {
              "Content-Type": "application/json",
              "Cache-Control": "no-store",
              "Pragma": "no-cache",
            }
            body = { error:, error_description: }

            [status, headers, body]
          end
        end
        #
        # class MyOAuthAuthorizationServerProvider
        #   def register_client(client_info)
        #     puts "Registering client: #{client_info[:client_id]}"
        #     # Raise RegistrationError.new('invalid_redirect_uri', 'One of the redirect_uris is invalid.')
        #     # Or succeed
        #   end
        # end
        #
        # class ClientRegistrationOptions
        #   def self.defaults
        #     {
        #       default_scopes: ['openid', 'profile', 'email'],
        #       valid_scopes: ['openid', 'profile', 'email', 'read:data', 'write:data'],
        #       client_secret_expiry_seconds: 3600 * 24 * 30 # 30 days
        #     }
        #   end
        # end
        #
        # # --- In a Rack app ---
        # # require 'rack'
        # #
        # # class App
        # #   def initialize
        # #     @provider = MyOAuthAuthorizationServerProvider.new
        # #     @options = ClientRegistrationOptions.defaults
        # #     @registration_handler = RegistrationHandler.new(@provider, @options)
        # #   end
        # #
        # #   def call(env)
        # #     request = Rack::Request.new(env)
        # #     if request.path_info == '/register' && request.post?
        # #       # Assuming async is handled by the server (e.g., Puma with async.callback)
        # #       # For simplicity, calling it synchronously here:
        # #       status, headers, body = @registration_handler.handle(request)
        # #       Rack::Response.new(body, status, headers).finish
        # #     else
        # #       [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
        # #     end
        # #   end
        # # end
        #
        # # To run this example (simplified):
        # # app = App.new
        # # server = Rack::Handler::WEBrick
        # # server.run app, Port: 9292
      end
    end
  end
end
