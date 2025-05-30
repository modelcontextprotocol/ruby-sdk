# frozen_string_literal: true

module MCP
  module Auth
    module Server
      class StateRegistry
        def create(state_id, state)
          raise NotImplementedError, "Subclasses must implement"
        end

        def find_by_id(state_id)
          raise NotImplementedError, "Subclasses must implement"
        end
      end

      class InMemoryStateRegistry < StateRegistry
        def initialize
          super
          @states = {}
        end

        def create(state_id, state)
          raise ArgumentError, "State with id '#{state_id}' already exists" if @states.key?(state_id)

          @states[state_id] = state
        end

        def find_by_id(state_id)
          @states[state_id]
        end
      end
    end
  end
end
