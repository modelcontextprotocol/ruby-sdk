# frozen_string_literal: true

require_relative "resource/contents"
require_relative "resource/embedded"

module MCP
  class Resource
    class << self
      NOT_SET = Object.new

      attr_reader :uri_value
      attr_reader :title_value
      attr_reader :description_value
      attr_reader :icons_value
      attr_reader :mime_type_value
      attr_reader :annotations_value
      attr_reader :size_value
      attr_reader :meta_value

      def contents(server_context: nil)
        raise NotImplementedError, "Subclasses must implement contents"
      end

      def to_h
        {
          uri: uri_value,
          name: name_value,
          title: title_value,
          description: description_value,
          icons: icons_value&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
          mimeType: mime_type_value,
          annotations: annotations_value&.to_h,
          size: size_value,
          _meta: meta_value,
        }.compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@uri_value, nil)
        subclass.instance_variable_set(:@name_value, nil)
        subclass.instance_variable_set(:@title_value, nil)
        subclass.instance_variable_set(:@description_value, nil)
        subclass.instance_variable_set(:@icons_value, nil)
        subclass.instance_variable_set(:@mime_type_value, nil)
        subclass.instance_variable_set(:@annotations_value, nil)
        subclass.instance_variable_set(:@size_value, nil)
        subclass.instance_variable_set(:@meta_value, nil)
      end

      def uri(value = NOT_SET)
        if value == NOT_SET
          @uri_value
        else
          @uri_value = value
        end
      end

      def resource_name(value = NOT_SET)
        if value == NOT_SET
          name_value
        else
          @name_value = value
        end
      end

      def name_value
        @name_value || (name.nil? ? nil : StringUtils.handle_from_class_name(name))
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

      def icons(value = NOT_SET)
        if value == NOT_SET
          @icons_value
        else
          @icons_value = value
        end
      end

      def mime_type(value = NOT_SET)
        if value == NOT_SET
          @mime_type_value
        else
          @mime_type_value = value
        end
      end

      def annotations(value = NOT_SET)
        if value == NOT_SET
          @annotations_value
        else
          @annotations_value = value.is_a?(Annotations) ? value : Annotations.new(**value)
        end
      end

      def size(value = NOT_SET)
        if value == NOT_SET
          @size_value
        else
          @size_value = value
        end
      end

      def meta(value = NOT_SET)
        if value == NOT_SET
          @meta_value
        else
          @meta_value = value
        end
      end

      def define(uri: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, size: nil, meta: nil, &block)
        Class.new(self) do
          uri uri
          resource_name name
          title title
          description description
          icons icons
          mime_type mime_type
          self.annotations(annotations) if annotations
          size size
          meta meta
          define_singleton_method(:contents, &block) if block
        end
      end
    end

    attr_reader :uri, :name, :title, :description, :icons, :mime_type, :annotations, :size, :meta

    def initialize(uri:, name:, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, size: nil, meta: nil)
      @uri = uri
      @name = name
      @title = title
      @description = description
      @icons = icons
      @mime_type = mime_type
      @annotations = annotations
      @size = size
      @meta = meta
    end

    def to_h
      {
        uri: uri,
        name: name,
        title: title,
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        mimeType: mime_type,
        annotations: annotations&.to_h,
        size: size,
        _meta: meta,
      }.compact
    end
  end
end
