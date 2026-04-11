# frozen_string_literal: true

module MCP
  class Prompt
    class Result
      attr_reader :description, :messages, :meta

      def initialize(description: nil, messages: [], meta: nil)
        @description = description
        @messages = messages
        @meta = meta
      end

      def to_h
        { description: description, messages: messages.map(&:to_h), _meta: meta }.compact
      end
    end
  end
end
