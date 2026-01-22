# frozen_string_literal: true

module MCP
  class Resource < Primitive
    class << self
      attr_reader :uri_value
      attr_reader :mime_type_value

      def to_h
        super.merge(
          uri: uri_value,
          mimeType: mime_type_value,
        ).compact
      end

      def contents
        raise NotImplementedError, "Subclasses must implement contents"
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@uri_value, nil)
        subclass.instance_variable_set(:@mime_type_value, nil)
      end

      alias_method :resource_name, :primitive_name

      def uri(value = NOT_SET)
        if value == NOT_SET
          @uri_value
        else
          @uri_value = value
        end
      end

      def mime_type(value = NOT_SET)
        if value == NOT_SET
          @mime_type_value
        else
          @mime_type_value = value
        end
      end

      def define(uri: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, meta: nil, &block)
        super(name: name, title: title, description: description, icons: icons, meta: meta) do
          uri(uri)
          mime_type(mime_type)
          class_exec(&block) if block
        end
      end
    end

    attr_reader :uri, :mime_type

    def initialize(uri:, mime_type: nil, **kwargs)
      super(**kwargs)
      @uri = uri
      @mime_type = mime_type
    end

    def to_h
      super.merge(
        uri: uri,
        mimeType: mime_type,
      ).compact
    end
  end
end
