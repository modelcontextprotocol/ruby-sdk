# frozen_string_literal: true

module MCP
  class Client
    class Tool
      attr_reader :name, :description, :input_schema, :output_schema

      def initialize(name:, description:, input_schema:, output_schema: nil)
        @name = name
        @description = description
        @input_schema = input_schema
        @output_schema = output_schema
      end
    end
  end
end
