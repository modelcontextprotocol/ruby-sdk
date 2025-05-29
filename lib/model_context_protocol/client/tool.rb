# typed: false
# frozen_string_literal: true

module ModelContextProtocol
  module Client
    class Tool
      attr_reader :payload

      def initialize(payload)
        @payload = payload
      end

      def name
        payload["name"]
      end

      def description
        payload["description"]
      end

      def input_schema
        payload["inputSchema"]
      end
    end
  end
end
