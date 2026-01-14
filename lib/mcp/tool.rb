# frozen_string_literal: true

module MCP
  class Tool
    class << self
      NOT_SET = Object.new
      MAX_LENGTH_OF_NAME = 128

      attr_reader :title_value
      attr_reader :description_value
      attr_reader :icons_value
      attr_reader :annotations_value
      attr_reader :meta_value

      def call(*args, server_context: nil)
        raise NotImplementedError, "Subclasses must implement call"
      end

      def to_h
        {
          name: name_value,
          title: title_value,
          description: description_value,
          icons: icons_value&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
          inputSchema: input_schema_value.to_h,
          outputSchema: @output_schema_value&.to_h,
          annotations: annotations_value&.to_h,
          _meta: meta_value,
        }.compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@name_value, nil)
        subclass.instance_variable_set(:@title_value, nil)
        subclass.instance_variable_set(:@description_value, nil)
        subclass.instance_variable_set(:@icons_value, nil)
        subclass.instance_variable_set(:@input_schema_value, nil)
        subclass.instance_variable_set(:@output_schema_value, nil)
        subclass.instance_variable_set(:@annotations_value, nil)
        subclass.instance_variable_set(:@meta_value, nil)
      end

      def tool_name(value = NOT_SET)
        if value == NOT_SET
          name_value
        else
          @name_value = value

          validate!
        end
      end

      def name_value
        @name_value || (name.nil? ? nil : StringUtils.handle_from_class_name(name))
      end

      def input_schema_value
        @input_schema_value || InputSchema.new
      end

      attr_reader :output_schema_value

      def title(value = NOT_SET)
        if value == NOT_SET
          @title_value
        else
          @title_value = value
        end
      end

      def description(value = NOT_SET)
        if value == NOT_SET
          @description_value
        else
          @description_value = value
        end
      end

      def icons(value = NOT_SET)
        if value == NOT_SET
          @icons_value
        else
          @icons_value = value
        end
      end

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

      def meta(value = NOT_SET)
        if value == NOT_SET
          @meta_value
        else
          @meta_value = value
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
        Class.new(self) do
          tool_name name
          title title
          description description
          icons icons
          input_schema input_schema
          meta meta
          output_schema output_schema
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
