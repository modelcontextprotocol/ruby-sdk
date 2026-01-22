# frozen_string_literal: true

require "test_helper"

module MCP
  class ResourceTest < ActiveSupport::TestCase
    test "#to_h does not have `:icons` key when icons is empty" do
      resource = Resource.new(
        uri: "file:///test.txt",
        name: "resource_without_icons",
        description: "a resource without icons",
      )

      refute resource.to_h.key?(:icons)
    end

    test "#to_h does not have `:icons` key when icons is nil" do
      resource = Resource.new(
        uri: "file:///test.txt",
        name: "resource_without_icons",
        description: "a resource without icons",
        icons: nil,
      )

      refute resource.to_h.key?(:icons)
    end

    test "#to_h includes icons when present" do
      resource = Resource.new(
        uri: "file:///test.txt",
        name: "resource_with_icons",
        description: "a resource with icons",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
      )
      expected_icons = [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }]

      assert_equal expected_icons, resource.to_h[:icons]
    end

    test "#to_h returns a hash including uri, name, description, icons, and mimeType" do
      expected = {
        uri: "file:///test.txt",
        name: "mock_resource",
        title: "Mock Resource",
        description: "a mock resource for testing",
        icons: [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }],
        mimeType: "text/plain",
      }
      resource = Resource.define(
        uri: "file:///test.txt",
        name: "mock_resource",
        title: "Mock Resource",
        description: "a mock resource for testing",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
        mime_type: "text/plain",
      )

      assert_equal(expected, resource.to_h)
    end

    test "#to_h does not have `:title` key when title is omitted" do
      resource = Resource.define(
        uri: "file:///test.txt",
        name: "mock_resource",
        description: "a mock resource for testing",
      )
      refute resource.to_h.key?(:title)
    end

    test "allows declarative definition of resources as classes" do
      class MockResource < Resource
        uri "file:///mock_resource.txt"
        resource_name "my_mock_resource"
        description "a mock resource for testing"
        mime_type "text/plain"

        class << self
          def contents
            [MCP::Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "Mock Content")]
          end
        end
      end

      resource = MockResource
      assert_equal "file:///mock_resource.txt", resource.uri
      assert_equal "my_mock_resource", resource.name_value
      assert_equal "a mock resource for testing", resource.description
      assert_equal "text/plain", resource.mime_type

      contents = resource.contents
      assert_equal 1, contents.size
      assert_instance_of MCP::Resource::TextContents, contents.first
      assert_equal "Mock Content", contents.first.text
    end

    test ".define allows definition of resources with a block implementing contents" do
      resource = Resource.define(
        uri: "file:///block_resource.txt",
        name: "block_resource",
      ) do
        class << self
          def contents
            [MCP::Resource::TextContents.new(uri: uri, mime_type: "text/plain", text: "Block Content")]
          end
        end
      end

      assert_equal "file:///block_resource.txt", resource.uri
      assert_equal "block_resource", resource.name_value

      contents = resource.contents
      assert_equal 1, contents.size
      assert_instance_of MCP::Resource::TextContents, contents.first
      assert_equal "Block Content", contents.first.text
    end
  end
end
