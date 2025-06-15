# frozen_string_literal: true

require "test_helper"

module MCP
  class AnnotationsTest < ActiveSupport::TestCase
    test "initializes with no parameters" do
      annotations = Annotations.new

      assert_nil annotations.audience
      assert_nil annotations.priority
    end

    test "initializes with audience only" do
      annotations = Annotations.new(audience: :internal)

      assert_equal :internal, annotations.audience
      assert_nil annotations.priority
    end

    test "initializes with priority only" do
      annotations = Annotations.new(priority: 1)

      assert_nil annotations.audience
      assert_equal 1, annotations.priority
    end

    test "initializes with both audience and priority" do
      annotations = Annotations.new(audience: :public, priority: 10)

      assert_equal :public, annotations.audience
      assert_equal 10, annotations.priority
    end

    test "instance is frozen after initialization" do
      annotations = Annotations.new

      assert_predicate annotations, :frozen?
    end

    test "to_h returns empty hash when no parameters are set" do
      annotations = Annotations.new
      result = annotations.to_h

      assert_empty(result)
      assert_predicate result, :frozen?
    end

    test "to_h returns hash with audience only" do
      annotations = Annotations.new(audience: :internal)
      result = annotations.to_h

      assert_equal({ audience: :internal }, result)
      assert_predicate result, :frozen?
    end

    test "to_h returns hash with priority only" do
      annotations = Annotations.new(priority: 5)
      result = annotations.to_h

      assert_equal({ priority: 5 }, result)
      assert_predicate result, :frozen?
    end

    test "to_h returns hash with both audience and priority" do
      annotations = Annotations.new(audience: :public, priority: 10)
      result = annotations.to_h

      assert_equal({ audience: :public, priority: 10 }, result)
      assert_predicate result, :frozen?
    end

    test "to_h compacts nil values" do
      annotations = Annotations.new(audience: nil, priority: 5)
      result = annotations.to_h

      assert_equal({ priority: 5 }, result)
      assert_not_includes result, :audience
    end
  end
end
