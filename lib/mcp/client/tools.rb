# typed: false
# frozen_string_literal: true

module MCP
  module Client
    class Tools
      include Enumerable

      attr_reader :response

      def initialize(response)
        @response = response
      end

      def each(&block)
        tools.each(&block)
      end

      def all
        tools
      end

      private

      def tools
        @tools ||= @response.dig("result", "tools")&.map { |tool| Tool.new(tool) } || []
      end
    end
  end
end
