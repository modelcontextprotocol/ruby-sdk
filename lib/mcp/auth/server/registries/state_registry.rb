# frozen_string_literal: true

module MCP
  module Auth
    module Server
      module Registries
        module StateRegistry
          def create_state(state_id, state)
            raise NotImplementedError, "#{self.class.name}#create_state is not implemented"
          end

          def find_state(state_id)
            raise NotImplementedError, "#{self.class.name}#find_state is not implemented"
          end

          def delete_state(state_id)
            raise NotImplementedError, "#{self.class.name}#delete_state is not implemented"
          end
        end
      end
    end
  end
end
