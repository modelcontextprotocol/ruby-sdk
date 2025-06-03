# frozen_string_literal: true

module MCP
  module Auth
    module Server
      module Registries
        module TokenRegistry
          def create_token(token_id, state)
            raise NotImplementedError, "#{self.class.name}#create_token is not implemented"
          end

          def find_token(token_id)
            raise NotImplementedError, "#{self.class.name}#find_token is not implemented"
          end

          def delete_token(token_id)
            raise NotImplementedError, "#{self.class.name}#delete_token is not implemented"
          end
        end
      end
    end
  end
end
