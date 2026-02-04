# frozen_string_literal: true

module MCP
  class Resource
    class Embedded
      attr_reader :resource, :annotations

      def initialize(resource:, annotations: nil)
        @resource = resource
        @annotations = annotations
      end

      def to_h
        { resource: resource.to_h, annotations: annotations }.compact
      end
    end
  end
end
