# frozen_string_literal: true

module MCP
  class Prompt
    class Message
      attr_reader :role, :content

      def initialize(role:, content:)
        @role = role
        @content = content
      end

      def to_h
        { role: role, content: content.to_h }.compact
      end
    end
  end
end
