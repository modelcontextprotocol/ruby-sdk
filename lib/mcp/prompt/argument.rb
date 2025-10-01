# frozen_string_literal: true

module MCP
  class Prompt
    class Argument
      attr_reader :name, :description, :required, :arguments

      def initialize(name:, description: nil, required: false)
        @name = name
        @description = description
        @required = required
        @arguments = arguments
      end

      def to_h
        { name:, description:, required: }.compact
      end
    end
  end
end
