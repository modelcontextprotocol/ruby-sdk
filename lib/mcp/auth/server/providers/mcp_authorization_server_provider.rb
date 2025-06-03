# frozen_string_literal: true

require "securerandom"
require "net/http"
require_relative "../../../serialization_utils"
require_relative "../provider"
require_relative "../../models"

module MCP
  module Auth
    module Server
      module Providers
        class McpAuthServerSettings
          attr_reader :issuer_url,
            :client_registration_options,
            :client_id,
            :client_secret,
            :auth_server_scopes,
            :auth_server_authorization_endpoint,
            :auth_server_token_endpoint,
            :mcp_callback_endpoint,
            :mcp_access_token_expiry_in_s

          def initialize(
            issuer_url:,
            client_registration_options:,
            client_id:,
            client_secret:,
            auth_server_scopes:,
            auth_server_authorization_endpoint:,
            auth_server_token_endpoint:,
            mcp_callback_endpoint:,
            mcp_access_token_expiry_in_s: 3600
          )
            @issuer_url = issuer_url
            @client_registration_options = client_registration_options
            @client_id = client_id
            @client_secret = client_secret
            @auth_server_scopes = auth_server_scopes
            @auth_server_authorization_endpoint = auth_server_authorization_endpoint
            @auth_server_token_endpoint = auth_server_token_endpoint
            @mcp_callback_endpoint = mcp_callback_endpoint
            @mcp_access_token_expiry_in_s = mcp_access_token_expiry_in_s
          end
        end

        class McpAuthorizationServerProvider
          include OAuthAuthorizationServerProvider
          include SerializationUtils

          FIVE_MINUTES_IN_SECONDS = 300

          def initialize(
            auth_server_settings:,
            client_registry:,
            state_registry:,
            auth_code_registry:,
            token_registry:
          )
            @settings = auth_server_settings
            @client_registry = client_registry
            @state_registry = state_registry
            @auth_code_registry = auth_code_registry
            @token_registry = token_registry
          end

          def oauth_metadata
            Models::OAuthMetadata.with_defaults(
              issuer_url: @settings.issuer_url,
              client_registration_options: @settings.client_registration_options,
            )
          end

          def client_registration_options
            @settings.client_registration_options
          end

          def get_client(client_id)
            @client_registry.find_client(client_id)
          end

          def register_client(client_info)
            @client_registry.create_client(client_info)
          end

          def authorize(auth_params)
            state = auth_params.state || SecureRandom.hex(16)
            @state_registry.create_state(state, auth_params)

            auth_url = URI(@settings.auth_server_authorization_endpoint)
            auth_url.query = URI.encode_www_form([
              ["client_id", @settings.client_id],
              ["redirect_uri", @settings.mcp_callback_endpoint],
              ["scope", @settings.auth_server_scopes],
              ["state", state],
              ["response_type", auth_params.response_type],
            ])

            auth_url.to_s
          end

          def authorize_callback(code:, state:)
            state_data = @state_registry.find_state(state)
            raise Errors::AuthorizationError.invalid_request("invalid state parameter") if state_data.nil?

            access_token_3p = query_access_token!({
              client_id: @settings.client_id,
              client_secret: @settings.client_secret,
              code:,
              redirect_uri: @settings.mcp_callback_endpoint,
              grant_type: "authorization_code",
            })

            mcp_auth_code = "mcp_#{SecureRandom.hex(16)}"
            auth_code = MCP::Auth::Server::AuthorizationCode.new(
              code: mcp_auth_code,
              client_id: state_data.client_id,
              redirect_uri: state_data.redirect_uri,
              redirect_uri_provided_explicitly: state_data.redirect_uri_provided_explicitly,
              expires_at: Time.now.to_i + FIVE_MINUTES_IN_SECONDS,
              scopes: ["mcp:user"],
              code_challenge: state_data.code_challenge,
            )
            @auth_code_registry.create_auth_code(mcp_auth_code, auth_code)
            @token_registry.create_token(mcp_auth_code, AccessToken.new(
              token: access_token_3p,
              client_id: state_data.client_id,
              scopes: @settings.auth_server_scopes,
              expires_at: nil,
            ))

            redirect_uri = URI(state_data.redirect_uri)
            redirect_uri.query = URI.encode_www_form([
              ["code", mcp_auth_code],
              ["state", state],
            ])
            @state_registry.delete_state(state)

            redirect_uri
          end

          def load_authorization_code(authorization_code)
            @auth_code_registry.find_auth_code(authorization_code)
          end

          def exchange_authorization_code(authorization_code)
            if @auth_code_registry.find_auth_code(authorization_code.code).nil?
              raise Errors::AuthorizationError.invalid_request("invalid authorization code")
            end

            mcp_token = "mcp_#{SecureRandom.hex(32)}"
            @token_registry.create_token(mcp_token, AccessToken.new(
              token: mcp_token,
              client_id: authorization_code.client_id,
              scopes: authorization_code.scopes,
              expires_at: Time.now.to_i + @settings.mcp_access_token_expiry_in_s,
            ))

            access_token_3p = @token_registry.find_token(authorization_code.code)
            unless access_token_3p.nil?
              @token_registry.create_token("3p:#{mcp_token}", access_token_3p)
              @token_registry.delete_token(authorization_code.code)
            end

            @auth_code_registry.delete_auth_code(authorization_code.code)

            Models::OAuthToken.new(
              access_token: mcp_token,
              token_type: "bearer",
              expires_in: @settings.mcp_access_token_expiry_in_s,
              scope: authorization_code.scopes.join(" "),
              refresh_token: "none_for_now",
            )
          end

          private

          def query_access_token!(data)
            uri = URI(@settings.auth_server_token_endpoint)
            response = Net::HTTP.post_form(uri, stringify_keys(data))
            raise Errors::AuthorizationError.new(
              error_code: Errors::AuthorizationError::INVALID_REQUEST,
              message: "failed to exchange code for token",
            ) unless response.is_a?(Net::HTTPOK)

            data = JSON.parse(response.body)
            if data.key?("error")
              raise Errors::AuthorizationError.new(
                error_code: data["error"],
                message: data["error_description"] || data["error"],
              )
            end

            data["access_token"]
          end
        end
      end
    end
  end
end
