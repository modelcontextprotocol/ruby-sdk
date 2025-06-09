# frozen_string_literal: true

module MCP
  module Tool
    class InputSchema
      attr_reader :properties, :required, :to_h

      def initialize(properties: {}, required: [])
        @properties = properties
        @required = required

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
