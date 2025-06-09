# typed: strict
# frozen_string_literal: true

module MCP
  module Prompt
    class Argument
      attr_reader :name, :description, :required, :to_h

      def initialize(name:, description: nil, required: false)
        @name = name
        @description = description
        @required = required

        @to_h = {
          name:,
          description:,
          required:,
        }.compact.freeze

        freeze
      end
    end
  end
end
