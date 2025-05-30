# frozen_string_literal: true

require_relative "../client_registry"
require_relative "../state_registry"

module MCP
  module Auth
    module Server
      module Providers
        class McpAuthorizationServerProvider < OAuthAuthorizationServerProvider
          def initialize(
            client_registry: nil,
            state_registry: nil
          )
            @client_registry = client_registry || InMemoryClientRegistry.new
            @state_registry = state_registry || InMemoryStateRegistry.new
          end

          def get_client(client_id)
            @client_registry.find_by_id(client_id)
          end

          def register_client(client_info)
            @client_registry.create(client_info)
          end
        end
      end
    end
  end
end
