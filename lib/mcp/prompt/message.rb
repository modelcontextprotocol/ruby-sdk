# typed: strict
# frozen_string_literal: true

module MCP
  module Prompt
    class Message
      attr_reader :role, :content

      def initialize(role:, content:)
        @role = role
        @content = content
      end

      def to_h
        { role:, content: content.to_h }.compact
      end
    end
  end
end
