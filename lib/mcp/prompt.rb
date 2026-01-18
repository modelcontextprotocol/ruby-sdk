# frozen_string_literal: true

module MCP
  class Prompt < Primitive
    class << self
      attr_reader :arguments_value

      def template(args, server_context: nil)
        raise NotImplementedError, "Subclasses must implement template"
      end

      def to_h
        super.merge(
          arguments: arguments_value&.map(&:to_h),
        ).compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@arguments_value, nil)
      end

      alias_method :prompt_name, :primitive_name

      def arguments(value = NOT_SET)
        if value == NOT_SET
          @arguments_value
        else
          @arguments_value = value
        end
      end

      def define(name: nil, title: nil, description: nil, icons: [], arguments: [], meta: nil, &block)
        super(name: name, title: title, description: description, icons: icons, meta: meta) do
          arguments(arguments)
          define_singleton_method(:template) do |args, server_context: nil|
            instance_exec(args, server_context: server_context, &block)
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
