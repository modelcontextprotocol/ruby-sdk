# frozen_string_literal: true

require "test_helper"

module MCP
  class AnnotationsTest < ActiveSupport::TestCase
    def test_initialization
      annotations = Annotations.new(audience: ["developers"], priority: 0.8)

      assert_equal(["developers"], annotations.audience)
      assert_equal(0.8, annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({ audience: ["developers"], priority: 0.8 }, annotations.to_h)
    end

    def test_initialization_with_all_attributes
      timestamp = Time.utc(2025, 1, 12, 15, 0, 58).iso8601
      annotations = Annotations.new(audience: ["developers"], priority: 0.8, last_modified: timestamp)

      assert_equal(["developers"], annotations.audience)
      assert_equal(0.8, annotations.priority)
      assert_equal(timestamp, annotations.last_modified)

      assert_equal({ audience: ["developers"], priority: 0.8, lastModified: timestamp }, annotations.to_h)
    end

    def test_initialization_by_default
      annotations = Annotations.new

      assert_nil(annotations.audience)
      assert_nil(annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({}, annotations.to_h)
    end

    def test_initialization_with_partial_attributes
      annotations = Annotations.new(audience: ["developers"])

      assert_equal(["developers"], annotations.audience)
      assert_nil(annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({ audience: ["developers"] }, annotations.to_h)
    end

    def test_initialization_with_last_modified_only
      timestamp = Time.utc(2025, 1, 12, 15, 0, 58).iso8601
      annotations = Annotations.new(last_modified: timestamp)

      assert_nil(annotations.audience)
      assert_nil(annotations.priority)
      assert_equal(timestamp, annotations.last_modified)

      assert_equal({ lastModified: timestamp }, annotations.to_h)
    end
  end
end
