# frozen_string_literal: true

require "securerandom"
require_relative "../../../serialization_utils"
require_relative "../client_registry"
require_relative "../state_registry"
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

          def initialize(
            auth_server_settings:,
            client_registry: nil,
            state_registry: nil
          )
            @settings = auth_server_settings
            @client_registry = client_registry || InMemoryClientRegistry.new
            @state_registry = state_registry || InMemoryStateRegistry.new
          end

          def get_client(client_id)
            @client_registry.find_by_id(client_id)
          end

          def register_client(client_info)
            @client_registry.create(client_info)
          end

          def authorize(client_info:, auth_params:)
            state = auth_params.state || SecureRandom.hex(16)

            @state_registry.create(state, to_h(auth_params))

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
        end
      end
    end
  end
end
