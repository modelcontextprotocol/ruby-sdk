# frozen_string_literal: true

module MCP
  class Prompt
    class Argument
      attr_reader :name, :title, :description, :required

      def initialize(name:, title: nil, description: nil, required: false)
        @name = name
        @title = title
        @description = description
        @required = required
      end

      def to_h
        {
          name: name,
          title: title,
          description: description,
          required: required,
        }.compact
      end
    end
  end
end
