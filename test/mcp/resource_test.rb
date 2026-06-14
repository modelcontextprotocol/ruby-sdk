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

    test "#to_h omits _meta when nil" do
      resource = Resource.new(uri: "file:///test.txt", name: "resource_without_meta")

      refute resource.to_h.key?(:_meta)
    end

    test "#to_h includes _meta when present" do
      meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
      resource = Resource.new(uri: "file:///test.txt", name: "resource_with_meta", meta: meta)

      assert_equal meta, resource.to_h[:_meta]
    end

    test "#to_h omits size when nil" do
      resource = Resource.new(uri: "file:///test.txt", name: "resource_without_size")

      refute resource.to_h.key?(:size)
    end

    test "#to_h includes size when present" do
      resource = Resource.new(uri: "file:///test.txt", name: "resource_with_size", size: 12_345)

      assert_equal 12_345, resource.to_h[:size]
    end

    test "#to_h includes size when zero" do
      resource = Resource.new(uri: "file:///empty.txt", name: "empty_resource", size: 0)

      assert_equal 0, resource.to_h[:size]
    end

    test "#to_h omits annotations when nil" do
      resource = Resource.new(uri: "file:///test.txt", name: "resource_without_annotations")

      refute resource.to_h.key?(:annotations)
    end

    test "#to_h includes annotations when present" do
      annotations = Annotations.new(audience: ["user"], priority: 0.8, last_modified: "2025-01-12T15:00:58Z")
      resource = Resource.new(uri: "file:///test.txt", name: "resource_with_annotations", annotations: annotations)

      expected = { audience: ["user"], priority: 0.8, lastModified: "2025-01-12T15:00:58Z" }
      assert_equal expected, resource.to_h[:annotations]
    end
  end
end
