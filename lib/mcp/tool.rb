# frozen_string_literal: true

module MCP
  class Tool
    attr_reader :name, :description, :input_schema, :annotations, :to_h

    class << self
      def define(...) = new(...)
      private :new

      private

      def inherited(subclass)
        super
        raise TypeError, "#{self} should no longer be subclassed. Use #{self}.define factory method instead."
      end
    end

    def initialize(name:, description: nil, input_schema: nil, annotations: nil, &block)
      input_schema = InputSchema.new(**input_schema) if Hash === input_schema
      annotations  = Annotations.new(**annotations)  if Hash === annotations
      raise ArgumentError, "Tool definition requires a block" unless block

      @name         = name
      @description  = description
      @input_schema = input_schema
      @annotations  = annotations
      @block        = block

      @to_h = {
        name:,
        description:,
        inputSchema: input_schema&.to_h,
        annotations: annotations&.to_h,
      }.compact.freeze

      freeze
    end

    def call(args, server_context:)
      @block.call(args, server_context:)
    end
  end
end
