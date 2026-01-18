# frozen_string_literal: true

module MCP
  class Tool < Primitive
    class << self
      MAX_LENGTH_OF_NAME = 128

      attr_reader :output_schema_value
      attr_reader :annotations_value

      def input_schema_value
        @input_schema_value || InputSchema.new
      end

      def call(*args, server_context: nil)
        raise NotImplementedError, "Subclasses must implement call"
      end

      def to_h
        super.merge(
          inputSchema: input_schema_value.to_h,
          outputSchema: @output_schema_value&.to_h,
          annotations: annotations_value&.to_h,
        ).compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@input_schema_value, nil)
        subclass.instance_variable_set(:@output_schema_value, nil)
        subclass.instance_variable_set(:@annotations_value, nil)
      end

      def primitive_name(value = NOT_SET)
        if value == NOT_SET
          name_value
        else
          @name_value = value

          validate!
        end
      end
      alias_method :tool_name, :primitive_name

      def input_schema(value = NOT_SET)
        if value == NOT_SET
          input_schema_value
        elsif value.is_a?(Hash)
          @input_schema_value = InputSchema.new(value)
        elsif value.is_a?(InputSchema)
          @input_schema_value = value
        end
      end

      def output_schema(value = NOT_SET)
        if value == NOT_SET
          output_schema_value
        elsif value.is_a?(Hash)
          @output_schema_value = OutputSchema.new(value)
        elsif value.is_a?(OutputSchema)
          @output_schema_value = value
        end
      end

      def annotations(hash = NOT_SET)
        if hash == NOT_SET
          @annotations_value
        else
          @annotations_value = Annotations.new(**hash)
        end
      end

      def define(name: nil, title: nil, description: nil, icons: [], input_schema: nil, output_schema: nil, meta: nil, annotations: nil, &block)
        super(name: name, title: title, description: description, icons: icons, meta: meta) do
          input_schema(input_schema)
          output_schema(output_schema)
          self.annotations(annotations) if annotations
          define_singleton_method(:call, &block) if block
        end.tap(&:validate!)
      end

      # It complies with the following tool name specification:
      # https://modelcontextprotocol.io/specification/latest/server/tools#tool-names
      def validate!
        return true unless tool_name

        if tool_name.empty? || tool_name.length > MAX_LENGTH_OF_NAME
          raise ArgumentError, "Tool names should be between 1 and 128 characters in length (inclusive)."
        end

        unless tool_name.match?(/\A[A-Za-z\d_\-\.]+\z/)
          raise ArgumentError, <<~MESSAGE
            Tool names only allowed characters: uppercase and lowercase ASCII letters (A-Z, a-z), digits (0-9), underscore (_), hyphen (-), and dot (.).
          MESSAGE
        end
      end
    end
  end
end
