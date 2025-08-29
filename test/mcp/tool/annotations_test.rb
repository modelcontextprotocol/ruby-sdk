# frozen_string_literal: true

require "test_helper"

module MCP
  class Tool
    class AnnotationsTest < ActiveSupport::TestCase
      test "Tool::Annotations initializes with all properties" do
        annotations = Tool::Annotations.new(
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false,
          read_only_hint: true,
          title: "Test Tool",
        )

        refute annotations.destructive_hint
        assert annotations.idempotent_hint
        refute annotations.open_world_hint
        assert annotations.read_only_hint
        assert_equal "Test Tool", annotations.title
      end

      test "Tool::Annotations initializes with partial properties" do
        annotations = Tool::Annotations.new(
          read_only_hint: true,
          title: "Test Tool",
        )

        assert annotations.destructive_hint
        refute annotations.idempotent_hint
        assert annotations.open_world_hint
        assert annotations.read_only_hint
        assert_equal "Test Tool", annotations.title
      end

      test "Tool::Annotations#to_h omits nil values" do
        annotations = Tool::Annotations.new(
          title: "Test Tool",
          read_only_hint: true,
        )

        expected = {
          destructiveHint: true,
          idempotentHint: false,
          openWorldHint: true,
          readOnlyHint: true,
          title: "Test Tool",
        }
        assert_equal expected, annotations.to_h
      end

      test "Tool::Annotations#to_h handles all properties" do
        annotations = Tool::Annotations.new(
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false,
          read_only_hint: true,
          title: "Test Tool",
        )

        expected = {
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false,
          readOnlyHint: true,
          title: "Test Tool",
        }
        assert_equal expected, annotations.to_h
      end

      test "Tool::Annotations#to_h returns hash with default hint values" do
        annotations = Tool::Annotations.new
        assert_equal({ destructiveHint: true, idempotentHint: false, openWorldHint: true, readOnlyHint: false }, annotations.to_h)
      end
    end
  end
end
