# frozen_string_literal: true

module MCP
  class Annotations
    attr_reader :audience, :priority, :last_modified

    def initialize(audience: nil, priority: nil, last_modified: nil)
      raise ArgumentError, "The value of priority must be between 0 and 1." if priority && !priority.between?(0, 1)

      @audience = audience
      @priority = priority
      @last_modified = last_modified
    end

    def to_h
      {
        audience: audience,
        priority: priority,
        lastModified: last_modified,
      }.compact
    end
  end
end
