# frozen_string_literal: true

module MCP
  class Annotations
    attr_reader :audience, :priority

    def initialize(audience: nil, priority: nil)
      @audience = audience
      @priority = priority

      freeze
    end

    def to_h
      { audience:, priority: }.compact.freeze
    end
  end
end
