# frozen_string_literal: true

require "test_helper"

module MCP
  module Elicitation
    class EnumSchemaTest < ActiveSupport::TestCase
      test "untitled_single_select returns string + enum schema" do
        schema = EnumSchema.untitled_single_select(values: ["red", "green", "blue"])

        assert_equal({ type: "string", enum: ["red", "green", "blue"] }, schema.to_h)
      end

      test "untitled_single_select preserves default value" do
        schema = EnumSchema.untitled_single_select(values: ["red", "green"], default: "red")

        assert_equal "red", schema.to_h[:default]
      end

      test "titled_single_select returns string + oneOf schema" do
        schema = EnumSchema.titled_single_select(
          options: [
            { value: "small", title: "Small" },
            { value: "large", title: "Large" },
          ],
        )

        assert_equal(
          {
            type: "string",
            oneOf: [
              { const: "small", title: "Small" },
              { const: "large", title: "Large" },
            ],
          },
          schema.to_h,
        )
      end

      test "untitled_multi_select returns array + items.enum schema" do
        schema = EnumSchema.untitled_multi_select(values: ["a", "b", "c"])

        assert_equal(
          { type: "array", items: { type: "string", enum: ["a", "b", "c"] } },
          schema.to_h,
        )
      end

      test "untitled_multi_select preserves default array" do
        schema = EnumSchema.untitled_multi_select(values: ["a", "b"], default: ["a"])

        assert_equal ["a"], schema.to_h[:default]
      end

      test "titled_multi_select returns array + items.anyOf schema" do
        schema = EnumSchema.titled_multi_select(
          options: [
            { value: "us", title: "United States" },
            { value: "jp", title: "Japan" },
          ],
        )

        assert_equal(
          {
            type: "array",
            items: {
              anyOf: [
                { const: "us", title: "United States" },
                { const: "jp", title: "Japan" },
              ],
            },
          },
          schema.to_h,
        )
      end

      test "legacy_titled returns enum + enumNames" do
        schema = EnumSchema.legacy_titled(
          values: ["s", "m", "l"],
          value_titles: ["Small", "Medium", "Large"],
        )

        assert_equal(
          {
            type: "string",
            enum: ["s", "m", "l"],
            enumNames: ["Small", "Medium", "Large"],
          },
          schema.to_h,
        )
      end

      test "title and description are included when provided" do
        schema = EnumSchema.untitled_single_select(
          values: ["a"],
          title: "Color",
          description: "Pick a color",
        )

        assert_equal "Color", schema.to_h[:title]
        assert_equal "Pick a color", schema.to_h[:description]
      end

      test "raises ArgumentError when values array is empty" do
        assert_raises(ArgumentError) do
          EnumSchema.untitled_single_select(values: [])
        end
      end

      test "raises ArgumentError when titled options miss :value" do
        assert_raises(ArgumentError) do
          EnumSchema.titled_single_select(options: [{ title: "missing value" }])
        end
      end

      test "raises ArgumentError when titled options miss :title" do
        assert_raises(ArgumentError) do
          EnumSchema.titled_single_select(options: [{ value: "v" }])
        end
      end

      test "raises ArgumentError when legacy value_titles length differs" do
        assert_raises(ArgumentError) do
          EnumSchema.legacy_titled(values: ["a", "b"], value_titles: ["A"])
        end
      end

      test "preserves an empty-string default value" do
        # Regression for `unless @default.nil?`: empty-but-non-nil defaults must still survive `to_h`
        # (the guard distinguishes nil from "absent vs supplied", not truthy vs falsey).
        schema = EnumSchema.untitled_single_select(values: ["", "yes", "no"], default: "")

        assert_equal "", schema.to_h[:default]
      end

      test "preserves an empty-array default for multi-select" do
        schema = EnumSchema.untitled_multi_select(values: ["a", "b"], default: [])

        assert_equal [], schema.to_h[:default]
      end
    end
  end
end
