# frozen_string_literal: true

module MCP
  module Tool
    class InputSchema
      attr_reader :properties, :required

      def initialize(properties: {}, required: [])
        @properties = properties
        @required = required.map(&:to_sym)
      end

      def to_h
        { type: "object", properties:, required: }
      end

      def missing_required_arguments?(arguments)
        missing_required_arguments(arguments).any?
      end

      def missing_required_arguments(arguments)
        (required - arguments.keys.map(&:to_sym))
      end
    end
  end
end
