# frozen_string_literal: true

module MCP
  class Prompt
    class Result
      attr_reader :description, :messages

      def initialize(description: nil, messages: [])
        @description = description
        @messages = messages
      end

      def to_h
        { description: description, messages: messages.map(&:to_h) }.compact
      end
    end
  end
end
