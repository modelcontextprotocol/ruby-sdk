# frozen_string_literal: true

module MCP
  module Elicitation
    # Builds the four enum schema variants defined by MCP 2025-11-25 (SEP-1330) plus the legacy `enumNames` form
    # retained for backward compatibility.
    #
    # Each class method returns an `EnumSchema` instance; call `to_h` to get the property-value Hash and
    # pass it through `requested_schema` to `ServerSession#create_form_elicitation`.
    class EnumSchema
      class << self
        # Single-select with plain string values: `{ type: "string", enum: [...] }`.
        def untitled_single_select(values:, default: nil, title: nil, description: nil)
          validate_values!(values)

          new(
            type: "string",
            extras: { enum: values },
            default: default,
            title: title,
            description: description,
          )
        end

        # Single-select with display titles per option: `{ type: "string", oneOf: [{ const, title }, ...] }`.
        # `options` is an Array of `{ value:, title: }` hashes.
        def titled_single_select(options:, default: nil, title: nil, description: nil)
          validate_titled_options!(options)

          new(
            type: "string",
            extras: { oneOf: options.map { |o| { const: o[:value], title: o[:title] } } },
            default: default,
            title: title,
            description: description,
          )
        end

        # Multi-select with plain string values: `{ type: "array", items: { type: "string", enum: [...] } }`.
        def untitled_multi_select(values:, default: nil, title: nil, description: nil)
          validate_values!(values)

          new(
            type: "array",
            extras: { items: { type: "string", enum: values } },
            default: default,
            title: title,
            description: description,
          )
        end

        # Multi-select with display titles per option: `{ type: "array", items: { anyOf: [{ const, title }, ...] } }`.
        def titled_multi_select(options:, default: nil, title: nil, description: nil)
          validate_titled_options!(options)

          items_anyof = options.map { |o| { const: o[:value], title: o[:title] } }
          new(
            type: "array",
            extras: { items: { anyOf: items_anyof } },
            default: default,
            title: title,
            description: description,
          )
        end

        # Legacy single-select retained for backward compatibility with clients implementing
        # the pre-SEP-1330 form: `{ enum, enumNames }`.
        def legacy_titled(values:, value_titles:, default: nil, title: nil, description: nil)
          validate_values!(values)
          unless value_titles.is_a?(Array) && value_titles.length == values.length
            raise ArgumentError, "value_titles must be an Array of the same length as values"
          end

          new(
            type: "string",
            extras: { enum: values, enumNames: value_titles },
            default: default,
            title: title,
            description: description,
          )
        end

        private

        def validate_values!(values)
          unless values.is_a?(Array) && !values.empty?
            raise ArgumentError, "values must be a non-empty Array"
          end
        end

        def validate_titled_options!(options)
          unless options.is_a?(Array) && !options.empty?
            raise ArgumentError, "options must be a non-empty Array of {value:, title:} hashes"
          end

          options.each do |option|
            unless option.is_a?(Hash) && option.key?(:value) && option.key?(:title)
              raise ArgumentError, "each option must be a Hash with :value and :title keys"
            end
          end
        end
      end

      def initialize(type:, extras:, default: nil, title: nil, description: nil)
        @type = type
        @extras = extras
        @default = default
        @title = title
        @description = description
      end

      def to_h
        hash = { type: @type }.merge(@extras)
        hash[:title] = @title if @title
        hash[:description] = @description if @description
        hash[:default] = @default unless @default.nil?
        hash
      end
    end
  end
end
