# frozen_string_literal: true

require_relative "auth_code_registry"
require_relative "client_registry"
require_relative "state_registry"
require_relative "token_registry"

module MCP
  module Auth
    module Server
      module Registries
        class InMemoryRegistry
          include AuthCodeRegistry
          include ClientRegistry
          include StateRegistry
          include TokenRegistry

          def initialize
            @codes = {}
            @clients = {}
            @states = {}
            @tokens = {}
          end

          def create_client(client_info)
            raise ArgumentError, "Client '#{client_info.client_id}' already exists" if @clients.key?(client_info.client_id)

            @clients[client_info.client_id] = client_info
          end

          def find_client(client_id)
            @clients[client_id]
          end

          def create_auth_code(code_id, data)
            raise ArgumentError, "Code with id '#{code}' already exists" if @codes.key?(code_id)

            @codes[code_id] = data
          end

          def find_auth_code(code_id)
            @codes[code_id]
          end

          def delete_auth_code(code_id)
            @codes.delete(code_id)
          end

          def create_state(state_id, state)
            raise ArgumentError, "State with id '#{state_id}' already exists" if @states.key?(state_id)

            @states[state_id] = state
          end

          def find_state(state_id)
            @states[state_id]
          end

          def delete_state(state_id)
            @states.delete(state_id)
          end

          def create_token(token_id, token)
            raise ArgumentError, "Token with id '#{token_id}' already exists" if @tokens.key?(token_id)

            @tokens[token_id] = token
          end

          def find_token(token_id)
            @tokens[token_id]
          end

          def delete_token(token_id)
            @tokens.delete(token_id)
          end
        end
      end
    end
  end
end
