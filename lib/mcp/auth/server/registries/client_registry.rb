# frozen_string_literal: true

module MCP
  module Auth
    module Server
      module Registries
        module ClientRegistry
          def create_client(client_info)
            raise NotImplementedError, "#{self.class.name}#create_client is not implemented"
          end

          def find_client(client_id)
            raise NotImplementedError, "#{self.class.name}#find_client is not implemented"
          end
        end
      end
    end
  end
end
