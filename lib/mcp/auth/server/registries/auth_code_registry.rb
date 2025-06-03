# frozen_string_literal: true

module MCP
  module Auth
    module Server
      module Registries
        module AuthCodeRegistry
          def create_auth_code(code_id, data)
            raise NotImplementedError, "#{self.class.name}#create_auth_code is not implemented"
          end

          def find_auth_code(code_id)
            raise NotImplementedError, "#{self.class.name}#find_auth_code is not implemented"
          end

          def delete_auth_code(code_id)
            raise NotImplementedError, "#{self.class.name}#delete_auth_code is not implemented"
          end
        end
      end
    end
  end
end
