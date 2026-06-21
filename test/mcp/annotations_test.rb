# frozen_string_literal: true

require "test_helper"

module MCP
  class AnnotationsTest < ActiveSupport::TestCase
    def test_initialization
      annotations = Annotations.new(audience: ["user"], priority: 0.8)

      assert_equal(["user"], annotations.audience)
      assert_equal(0.8, annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({ audience: ["user"], priority: 0.8 }, annotations.to_h)
    end

    def test_initialization_with_all_attributes
      timestamp = Time.utc(2025, 1, 12, 15, 0, 58).iso8601
      annotations = Annotations.new(audience: ["user"], priority: 0.8, last_modified: timestamp)

      assert_equal(["user"], annotations.audience)
      assert_equal(0.8, annotations.priority)
      assert_equal(timestamp, annotations.last_modified)

      assert_equal({ audience: ["user"], priority: 0.8, lastModified: timestamp }, annotations.to_h)
    end

    def test_initialization_by_default
      annotations = Annotations.new

      assert_nil(annotations.audience)
      assert_nil(annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({}, annotations.to_h)
    end

    def test_initialization_with_partial_attributes
      annotations = Annotations.new(audience: ["user"])

      assert_equal(["user"], annotations.audience)
      assert_nil(annotations.priority)
      assert_nil(annotations.last_modified)

      assert_equal({ audience: ["user"] }, annotations.to_h)
    end

    def test_initialization_with_last_modified_only
      timestamp = Time.utc(2025, 1, 12, 15, 0, 58).iso8601
      annotations = Annotations.new(last_modified: timestamp)

      assert_nil(annotations.audience)
      assert_nil(annotations.priority)
      assert_equal(timestamp, annotations.last_modified)

      assert_equal({ lastModified: timestamp }, annotations.to_h)
    end

    def test_valid_priority_at_lower_bound
      assert_nothing_raised do
        Annotations.new(priority: 0)
      end
    end

    def test_valid_priority_at_upper_bound
      assert_nothing_raised do
        Annotations.new(priority: 1)
      end
    end

    def test_invalid_priority_above_upper_bound
      exception = assert_raises(ArgumentError) do
        Annotations.new(priority: 1.5)
      end
      assert_equal("The value of priority must be between 0 and 1.", exception.message)
    end

    def test_invalid_priority_below_lower_bound
      exception = assert_raises(ArgumentError) do
        Annotations.new(priority: -0.1)
      end
      assert_equal("The value of priority must be between 0 and 1.", exception.message)
    end

    def test_valid_audience_with_user
      assert_nothing_raised do
        Annotations.new(audience: ["user"])
      end
    end

    def test_valid_audience_with_assistant
      assert_nothing_raised do
        Annotations.new(audience: ["assistant"])
      end
    end

    def test_valid_audience_with_multiple_roles
      assert_nothing_raised do
        Annotations.new(audience: ["user", "assistant"])
      end
    end

    def test_valid_audience_with_empty_array
      assert_nothing_raised do
        Annotations.new(audience: [])
      end
    end

    def test_invalid_audience_with_unknown_role
      exception = assert_raises(ArgumentError) do
        Annotations.new(audience: ["developers"])
      end
      assert_equal('The value of audience must be an array of "user" or "assistant".', exception.message)
    end

    def test_invalid_audience_with_mixed_roles
      exception = assert_raises(ArgumentError) do
        Annotations.new(audience: ["user", "developers"])
      end
      assert_equal('The value of audience must be an array of "user" or "assistant".', exception.message)
    end

    def test_invalid_audience_when_not_array
      exception = assert_raises(ArgumentError) do
        Annotations.new(audience: "user")
      end
      assert_equal('The value of audience must be an array of "user" or "assistant".', exception.message)
    end
  end
end
