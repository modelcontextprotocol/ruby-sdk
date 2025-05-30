# frozen_string_literal: true

module MCP
  module Auth
    module Server
      class ClientRegistry
        def create(client_info)
          raise NotImplementedError, "Subclasses must implement"
        end

        def find_by_id(client_id)
          raise NotImplementedError, "Subclasses must implement"
        end
      end

      class InMemoryClientRegistry < ClientRegistry
        def initialize
          super
          @clients = {}
        end

        def create(client_info)
          raise ArgumentError, "Client '#{client_info.client_id}' already exists" if @clients.key?(client_info.client_id)

          @clients[client_info.client_id] = client_info
        end

        def find_by_id(client_id)
          @clients[client_id]
        end
      end
    end
  end
end
