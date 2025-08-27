# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class AnnotationsTest < ActiveSupport::TestCase
      test "Tool::Annotations initializes with all properties" do
        annotations = Tool::Annotations.new(
          title: "Test Tool",
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false,
        )

        assert_equal "Test Tool", annotations.title
        assert annotations.read_only_hint
        refute annotations.destructive_hint
        assert annotations.idempotent_hint
        refute annotations.open_world_hint
      end

      test "Tool::Annotations initializes with partial properties" do
        annotations = Tool::Annotations.new(
          title: "Test Tool",
          read_only_hint: true,
        )

        assert_equal "Test Tool", annotations.title
        assert annotations.read_only_hint
        assert_nil annotations.destructive_hint
        assert_nil annotations.idempotent_hint
        assert_nil annotations.open_world_hint
      end

      test "Tool::Annotations#to_h omits nil values" do
        annotations = Tool::Annotations.new(
          title: "Test Tool",
          read_only_hint: true,
        )

        expected = {
          title: "Test Tool",
          readOnlyHint: true,
        }
        assert_equal expected, annotations.to_h
      end

      test "Tool::Annotations#to_h handles all properties" do
        annotations = Tool::Annotations.new(
          title: "Test Tool",
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false,
        )

        expected = {
          title: "Test Tool",
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
        }
        assert_equal expected, annotations.to_h
      end

      test "Tool::Annotations#to_h returns empty hash when all values are nil" do
        annotations = Tool::Annotations.new
        assert_empty annotations.to_h
      end
    end
  end
end
