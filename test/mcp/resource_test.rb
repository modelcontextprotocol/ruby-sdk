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

    class UserGuideResource < Resource
      uri "file:///docs/user_guide.md"
      title "User Guide"
      description "the user guide"
      icons [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")]
      mime_type "text/markdown"
      annotations audience: ["user"], priority: 0.5
      size 2_048
      meta({ "example" => "value" })

      class << self
        def contents
          [Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "guide body")]
        end
      end
    end

    test "class-based .to_h emits the same keys as the equivalent instance" do
      instance = Resource.new(
        uri: "file:///docs/user_guide.md",
        name: "user_guide_resource",
        title: "User Guide",
        description: "the user guide",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
        mime_type: "text/markdown",
        annotations: Annotations.new(audience: ["user"], priority: 0.5),
        size: 2_048,
        meta: { "example" => "value" },
      )

      assert_equal instance.to_h, UserGuideResource.to_h
    end

    test "class-based name defaults to the snake_cased class name" do
      assert_equal "user_guide_resource", UserGuideResource.name_value
    end

    test "explicit resource_name wins over the class name" do
      resource_class = Class.new(UserGuideResource) do
        resource_name "custom_name"
      end

      assert_equal "custom_name", resource_class.resource_name
      assert_equal "custom_name", resource_class.name_value
    end

    test "class-based .to_h omits keys that are not set" do
      resource_class = Class.new(Resource) do
        uri "file:///bare.txt"
        resource_name "bare"
      end

      assert_equal({ uri: "file:///bare.txt", name: "bare" }, resource_class.to_h)
    end

    test "class-level annotations accepts an Annotations instance" do
      annotations = Annotations.new(audience: ["assistant"])
      resource_class = Class.new(Resource) do
        annotations annotations
      end

      assert_same annotations, resource_class.annotations
    end

    test "subclasses of a configured class start clean" do
      subclass = Class.new(UserGuideResource)

      assert_nil subclass.uri
      assert_nil subclass.title
      assert_nil subclass.description
      assert_nil subclass.icons
      assert_nil subclass.mime_type
      assert_nil subclass.annotations
      assert_nil subclass.size
      assert_nil subclass.meta
    end

    test ".contents raises NotImplementedError unless implemented" do
      resource_class = Class.new(Resource)

      assert_raises(NotImplementedError) { resource_class.contents }
    end

    test ".define creates a resource class whose block implements contents" do
      resource_class = Resource.define(
        uri: "file:///defined.txt",
        name: "defined_resource",
        mime_type: "text/plain",
      ) do
        [Resource::TextContents.new(uri: uri, mime_type: mime_type, text: "defined body")]
      end

      assert_equal "file:///defined.txt", resource_class.uri
      assert_equal "defined_resource", resource_class.name_value

      contents = resource_class.contents
      assert_equal 1, contents.size
      assert_equal "defined body", contents.first.text
    end

    test ".define without a name omits :name from to_h" do
      resource_class = Resource.define(uri: "file:///anonymous.txt")

      refute resource_class.to_h.key?(:name)
    end
  end
end
