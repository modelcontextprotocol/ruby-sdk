# typed: strict
# frozen_string_literal: true

module MCP
  module Prompt
    attr_reader :name, :description, :arguments, :to_h

    class << self
      def define(...) = new(...)
      private :new

      private

      def inherited(subclass)
        super
        raise TypeError, "#{self} should no longer be subclassed. Use #{self}.define factory method instead."
      end
    end

    def initialize(name:, description:, arguments:, &block)
      arguments = arguments.map { |arg| Hash === arg ? Argument.new(**arg) : arg }

      @name = name
      @description = description
      @arguments = arguments
      @block = block

      @to_h = { name:, description:, arguments: arguments.map(&:to_h) }.compact.freeze

      freeze
    end

    def call(args, server_context:)
      @block.call(args, server_context:)
    end
  end
end
