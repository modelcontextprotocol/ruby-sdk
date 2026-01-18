# frozen_string_literal: true

module MCP
  class Primitive
    class << self
      NOT_SET = Object.new

      attr_reader :title_value
      attr_reader :description_value
      attr_reader :icons_value
      attr_reader :meta_value

      def name_value
        @name_value ||= StringUtils.handle_from_class_name(name)
      end

      def primitive_name(value = NOT_SET)
        if value == NOT_SET
          @name_value
        else
          @name_value = value
        end
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

      def meta(value = NOT_SET)
        if value == NOT_SET
          @meta_value
        else
          @meta_value = value
        end
      end

      def to_h
        {
          name: name_value,
          title: title_value,
          description: description_value,
          icons: icons_value&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
          _meta: meta_value,
        }.compact
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@name_value, nil)
        subclass.instance_variable_set(:@title_value, nil)
        subclass.instance_variable_set(:@description_value, nil)
        subclass.instance_variable_set(:@icons_value, nil)
        subclass.instance_variable_set(:@meta_value, nil)
      end

      def define(name: nil, title: nil, description: nil, icons: [], meta: nil, &block)
        Class.new(self) do
          primitive_name name
          title title
          description description
          icons icons
          meta meta
          class_exec(&block) if block
        end
      end
    end

    attr_reader :name, :title, :description, :icons, :meta

    def initialize(name:, title: nil, description: nil, icons: [], meta: nil)
      @name = name
      @title = title
      @description = description
      @icons = icons
      @meta = meta
    end

    def to_h
      {
        name: name,
        title: title,
        description: description,
        icons: icons&.then { |icons| icons.empty? ? nil : icons.map(&:to_h) },
        _meta: meta,
      }.compact
    end
  end
end
