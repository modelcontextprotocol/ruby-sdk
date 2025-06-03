# frozen_string_literal: true

require "securerandom"
require "net/http"
require_relative "../../../serialization_utils"
require_relative "../provider"

module MCP
  module Auth
    module Server
      module Providers
        class McpAuthServerSettings
          attr_reader :client_id,
            :client_secret,
            :auth_server_scopes,
            :auth_server_authorization_endpoint,
            :auth_server_token_endpoint,
            :mcp_callback_endpoint

          def initialize(
            client_id:,
            client_secret:,
            auth_server_scopes:,
            auth_server_authorization_endpoint:,
            auth_server_token_endpoint:,
            mcp_callback_endpoint:
          )
            @client_id = client_id
            @client_secret = client_secret
            @auth_server_scopes = auth_server_scopes
            @auth_server_authorization_endpoint = auth_server_authorization_endpoint
            @auth_server_token_endpoint = auth_server_token_endpoint
            @mcp_callback_endpoint = mcp_callback_endpoint
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

          def get_client(client_id)
            @client_registry.find_client(client_id)
          end

          def register_client(client_info)
            @client_registry.create_client(client_info)
          end

          def authorize(client_info:, auth_params:)
            state = auth_params.state || SecureRandom.hex(16)
            @state_registry.create_state(state, to_h(auth_params))

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

            access_token = query_access_token!({
              client_id: @settings.client_id,
              client_secret: @settings.client_secret,
              code:,
              redirect_uri: @settings.mcp_callback_endpoint,
              grant_type: "authorization_code",
            })

            mcp_auth_code = "mcp_#{SecureRandom.hex(16)}"
            auth_code = MCP::Auth::Server::AuthorizationCode.new(
              code: mcp_auth_code,
              client_id: state_data[:client_id],
              redirect_uri: state_data[:redirect_uri],
              redirect_uri_provided_explicitly: state_data[:redirect_uri_provided_explicitly],
              expires_at: Time.now.to_i + FIVE_MINUTES_IN_SECONDS,
              scopes: ["mcp:user"],
              code_challenge: state_data[:code_challenge],
            )
            @auth_code_registry.create_auth_code(mcp_auth_code, auth_code)
            @token_registry.create_token(mcp_auth_code, AccessToken.new(
              token: access_token,
              client_id: state_data[:client_id],
              scopes: @settings.auth_server_scopes,
              expires_at: nil,
            ))

            redirect_uri = URI(state_data[:redirect_uri])
            redirect_uri.query = URI.encode_www_form([
              ["code", mcp_auth_code],
              ["state", state],
            ])
            @state_registry.delete_state(state)

            redirect_uri
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
