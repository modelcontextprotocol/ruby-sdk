# frozen_string_literal: true

module MCP
  class Tool
    class InputSchema
      attr_reader :properties, :required, :to_h

      def initialize(properties: {}, required: [])
        @properties = properties.transform_keys(&:to_sym)
        @required = required.map(&:to_sym)

        @to_h = {
          type: "object",
          properties:,
          required:,
        }.compact.freeze

        freeze
      end
    end
  end
end
