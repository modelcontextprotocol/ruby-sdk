# frozen_string_literal: true

module MCP
  class Client
    class Tool
      attr_reader :name, :description, :input_schema, :output_schema, :annotations

      def initialize(name:, description:, input_schema:, output_schema: nil, annotations: nil)
        @name = name
        @description = description
        @input_schema = input_schema
        @output_schema = output_schema
        @annotations = annotations
      end
    end
  end
end
