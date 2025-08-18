# typed: strict
# frozen_string_literal: true

module MCP
  class Prompt
    class << self
      NOT_SET = Object.new

      attr_reader :title_value
      attr_reader :description_value
      attr_reader :arguments_value

      def template(args, server_context: nil)
        raise NotImplementedError, "Subclasses must implement template"
      end

      def to_h
        { name: name_value, title: title_value, description: description_value, arguments: arguments_value.map(&:to_h) }.compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@name_value, nil)
        subclass.instance_variable_set(:@title_value, nil)
        subclass.instance_variable_set(:@description_value, nil)
        subclass.instance_variable_set(:@arguments_value, nil)
      end

      def prompt_name(value = NOT_SET)
        if value == NOT_SET
          @name_value
        else
          @name_value = value
        end
      end

      def name_value
        @name_value || StringUtils.handle_from_class_name(name)
      end

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

      def arguments(value = NOT_SET)
        if value == NOT_SET
          @arguments_value
        else
          @arguments_value = value
        end
      end

      def define(name: nil, title: nil, description: nil, arguments: [], &block)
        Class.new(self) do
          prompt_name name
          title title
          description description
          arguments arguments
          define_singleton_method(:template) do |args, server_context: nil|
            instance_exec(args, server_context:, &block)
          end
        end
      end

      def validate_arguments!(args)
        missing = required_args - args.keys
        return if missing.empty?

        raise MCP::Server::RequestHandlerError.new(
          "Missing required arguments: #{missing.join(", ")}", nil, error_type: :missing_required_arguments
        )
      end

      private

      def required_args
        arguments_value.filter_map { |arg| arg.name.to_sym if arg.required }
      end
    end
  end
end
