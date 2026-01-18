# frozen_string_literal: true

module MCP
  class ResourceTemplate < Primitive
    class << self
      attr_reader :uri_template_value
      attr_reader :mime_type_value

      def to_h
        super.merge(
          uriTemplate: uri_template_value,
          mimeType: mime_type_value,
        ).compact
      end

      def contents(params:)
        raise NotImplementedError, "Subclasses must implement contents"
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@uri_template_value, nil)
        subclass.instance_variable_set(:@mime_type_value, nil)
      end

      alias_method :resource_template_name, :primitive_name

      def uri_template(value = NOT_SET)
        if value == NOT_SET
          @uri_template_value
        else
          @uri_template_value = value
        end
      end

      def mime_type(value = NOT_SET)
        if value == NOT_SET
          @mime_type_value
        else
          @mime_type_value = value
        end
      end

      def define(uri_template: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, meta: nil, &block)
        super(name: name, title: title, description: description, icons: icons, meta: meta) do
          uri_template(uri_template)
          mime_type(mime_type)
          class_exec(&block) if block
        end
      end
    end

    attr_reader :uri_template, :mime_type

    def initialize(uri_template:, mime_type: nil, **kwargs)
      super(**kwargs)
      @uri_template = uri_template
      @mime_type = mime_type
    end

    def to_h
      super.merge(
        uriTemplate: uri_template,
        mimeType: mime_type,
      ).compact
    end
  end
end
