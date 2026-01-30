# frozen_string_literal: true

require "test_helper"

module MCP
  class Resource
    class EmbeddedTest < ActiveSupport::TestCase
      test "initializes with resource" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          description: "a test resource",
        )
        embedded = Resource::Embedded.new(resource: resource)

        assert_equal resource, embedded.resource
      end

      test "initializes with resource and annotations" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          description: "a test resource",
        )
        annotations = { audience: ["user"], priority: 1.0 }
        embedded = Resource::Embedded.new(resource: resource, annotations: annotations)

        assert_equal resource, embedded.resource
        assert_equal annotations, embedded.annotations
      end

      test "initializes with annotations as nil when not provided" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          description: "a test resource",
        )
        embedded = Resource::Embedded.new(resource: resource)

        assert_nil embedded.annotations
      end

      test "#to_h returns hash with resource data when annotations is nil" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          description: "a test resource",
        )
        embedded = Resource::Embedded.new(resource: resource)

        expected = {
          resource: {
            uri: "file:///test.txt",
            name: "test_resource",
            description: "a test resource",
          },
        }

        assert_equal expected, embedded.to_h
      end

      test "#to_h returns hash with resource and annotations when both are present" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          description: "a test resource",
        )
        annotations = { audience: ["user"], priority: 1.0 }
        embedded = Resource::Embedded.new(resource: resource, annotations: annotations)

        expected = {
          resource: {
            uri: "file:///test.txt",
            name: "test_resource",
            description: "a test resource",
          },
          annotations: { audience: ["user"], priority: 1.0 },
        }

        assert_equal expected, embedded.to_h
      end

      test "#to_h handles resource with all optional fields" do
        resource = Resource.new(
          uri: "file:///test.txt",
          name: "test_resource",
          title: "Test Resource",
          description: "a test resource",
          mime_type: "text/plain",
        )
        embedded = Resource::Embedded.new(resource: resource)

        expected = {
          resource: {
            uri: "file:///test.txt",
            name: "test_resource",
            title: "Test Resource",
            description: "a test resource",
            mimeType: "text/plain",
          },
        }

        assert_equal expected, embedded.to_h
      end
    end
  end
end
