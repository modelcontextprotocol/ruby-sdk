# frozen_string_literal: true

require_relative "schema"

module MCP
  class Tool
    class OutputSchema < Schema
      class ValidationError < StandardError; end

      # Root-level keywords whose presence means the user already chose a root schema shape,
      # so no `type: "object"` default should be merged in.
      ROOT_SCHEMA_KEYWORDS = [:type, :"$ref", :oneOf, :anyOf, :allOf, :not, :if, :const, :enum].freeze

      def validate_result(result)
        errors = fully_validate(result)
        if errors.any?
          raise ValidationError, "Invalid result: #{errors.join(", ")}"
        end
      end

      private

      # Per SEP-2106, an output schema may be ANY valid JSON Schema 2020-12 document: object, array, primitive,
      # or a root-level composition.
      # Default the root to an object only when no root schema keyword is present, which preserves the wire output
      # of the common `properties`-only shape while leaving e.g. `{ type: "array" }` or `{ oneOf: [...] }` untouched
      # (the old unconditional default merged `type: "object"` into root combinators, producing a wrong schema).
      def apply_default_root_type!
        return if ROOT_SCHEMA_KEYWORDS.any? { |keyword| @schema.key?(keyword) }

        super
      end
    end
  end
end
