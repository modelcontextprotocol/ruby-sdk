# frozen_string_literal: true

module MCP
  class ResourceTemplate
    class << self
      NOT_SET = Object.new

      # Applied after `Regexp.escape`, which turns `{` and `}` into `\{` and `\}`.
      # Variable names are restricted to valid Regexp named-group names,
      # so RFC 6570 operator expressions (e.g. `{?query}`) stay literal and never match.
      VARIABLE_PATTERN = /\\\{([A-Za-z_]\w*)\\\}/

      attr_reader :uri_template_value
      attr_reader :title_value
      attr_reader :description_value
      attr_reader :icons_value
      attr_reader :mime_type_value
      attr_reader :annotations_value
      attr_reader :meta_value

      def contents(server_context: nil, **params)
        raise NotImplementedError, "Subclasses must implement contents"
      end

      def to_h
        {
          uriTemplate: uri_template_value,
          name: name_value,
          title: title_value,
          description: description_value,
          icons: icons_value&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
          mimeType: mime_type_value,
          annotations: annotations_value&.to_h,
          _meta: meta_value,
        }.compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@uri_template_value, nil)
        subclass.instance_variable_set(:@uri_template_pattern, nil)
        subclass.instance_variable_set(:@name_value, nil)
        subclass.instance_variable_set(:@title_value, nil)
        subclass.instance_variable_set(:@description_value, nil)
        subclass.instance_variable_set(:@icons_value, nil)
        subclass.instance_variable_set(:@mime_type_value, nil)
        subclass.instance_variable_set(:@annotations_value, nil)
        subclass.instance_variable_set(:@meta_value, nil)
      end

      def uri_template(value = NOT_SET)
        if value == NOT_SET
          @uri_template_value
        else
          @uri_template_pattern = nil
          @uri_template_value = value
        end
      end

      def resource_template_name(value = NOT_SET)
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

      def meta(value = NOT_SET)
        if value == NOT_SET
          @meta_value
        else
          @meta_value = value
        end
      end

      # Matches a concrete URI against the template's simple RFC 6570 level-1 `{var}` expressions.
      # Returns a symbol-keyed Hash of variable values, or `nil` if the URI does not match.
      # Variables match one or more characters excluding `/`, and values are not percent-decoded.
      def match_uri(uri)
        match = uri_template_pattern&.match(uri)
        match&.named_captures&.transform_keys(&:to_sym)
      end

      def define(uri_template: nil, name: nil, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, meta: nil, &block)
        Class.new(self) do
          uri_template uri_template
          resource_template_name name
          title title
          description description
          icons icons
          mime_type mime_type
          self.annotations(annotations) if annotations
          meta meta
          define_singleton_method(:contents, &block) if block
        end
      end

      private

      def uri_template_pattern
        return if uri_template.nil?

        @uri_template_pattern ||= begin
          pattern = Regexp.escape(uri_template).gsub(VARIABLE_PATTERN) { "(?<#{Regexp.last_match(1)}>[^/]+)" }
          Regexp.new("\\A#{pattern}\\z")
        end
      end
    end

    attr_reader :uri_template, :name, :title, :description, :icons, :mime_type, :annotations, :meta

    def initialize(uri_template:, name:, title: nil, description: nil, icons: [], mime_type: nil, annotations: nil, meta: nil)
      @uri_template = uri_template
      @name = name
      @title = title
      @description = description
      @icons = icons
      @mime_type = mime_type
      @annotations = annotations
      @meta = meta
    end

    def to_h
      {
        uriTemplate: uri_template,
        name: name,
        title: title,
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        mimeType: mime_type,
        annotations: annotations&.to_h,
        _meta: meta,
      }.compact
    end
  end
end
