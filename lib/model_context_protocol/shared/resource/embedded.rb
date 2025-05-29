# typed: strict
# frozen_string_literal: true

module ModelContextProtocol
  class Resource
    class Embedded
      attr_reader :resource, :annotations

      def initialize(resource:, annotations: nil)
        @annotations = annotations
      end

      def to_h
        { resource: resource.to_h, annotations: }.compact
      end
    end
  end
end
