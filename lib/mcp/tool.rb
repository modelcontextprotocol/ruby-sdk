# frozen_string_literal: true

module MCP
  module Tool
    NOT_SET = Object.new

    attr_reader :description_value
    attr_reader :input_schema_value
    attr_reader :annotations_value

    class << self
      def define(name: nil, description: nil, input_schema: nil, annotations: nil, &block)
        Module.new do
          extend Tool
          tool_name name
          description description
          input_schema input_schema
          annotations annotations if annotations
          define_singleton_method(:call, &block) if block
        end
      end
    end

    def call(*args, server_context:)
      raise NotImplementedError, "Tools must implement call"
    end

    def to_h
      result = {
        name: name_value,
        description: description_value,
        inputSchema: input_schema_value.to_h,
      }
      result[:annotations] = annotations_value.to_h if annotations_value
      result
    end

    def extended(mod)
      super
      mod.instance_variable_set(:@name_value, nil)
      mod.instance_variable_set(:@description_value, nil)
      mod.instance_variable_set(:@input_schema_value, nil)
      mod.instance_variable_set(:@annotations_value, nil)
    end

    def tool_name(value = NOT_SET)
      if value == NOT_SET
        name_value
      else
        @name_value = value
      end
    end

    def name_value
      @name_value || StringUtils.handle_from_class_name(name)
    end

    def description(value = NOT_SET)
      if value == NOT_SET
        @description_value
      else
        @description_value = value
      end
    end

    def input_schema(value = NOT_SET)
      if value == NOT_SET
        input_schema_value
      elsif value.is_a?(Hash)
        properties = value[:properties] || value["properties"] || {}
        required = value[:required] || value["required"] || []
        @input_schema_value = InputSchema.new(properties:, required:)
      elsif value.is_a?(InputSchema)
        @input_schema_value = value
      end
    end

    def annotations(hash = NOT_SET)
      if hash == NOT_SET
        @annotations_value
      else
        @annotations_value = Annotations.new(**hash)
      end
    end
  end
end
