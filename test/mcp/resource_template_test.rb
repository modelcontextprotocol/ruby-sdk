# frozen_string_literal: true

require "test_helper"

module MCP
  class ResourceTemplateTest < ActiveSupport::TestCase
    test "#to_h does not have `:icons` key when icons is empty" do
      resource_template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "resource_template_without_icons",
        description: "a resource template without icons",
      )

      refute resource_template.to_h.key?(:icons)
    end

    test "#to_h does not have `:icons` key when icons is nil" do
      resource_template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "resource_template_without_icons",
        description: "a resource template without icons",
        icons: nil,
      )

      refute resource_template.to_h.key?(:icons)
    end

    test "#to_h includes icons when present" do
      resource_template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "resource_template_with_icons",
        description: "a resource template with icons",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
      )
      expected_icons = [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }]

      assert_equal expected_icons, resource_template.to_h[:icons]
    end

    test "#to_h omits _meta when nil" do
      resource_template = ResourceTemplate.new(uri_template: "file:///{path}", name: "template_without_meta")

      refute resource_template.to_h.key?(:_meta)
    end

    test "#to_h includes _meta when present" do
      meta = { "application/vnd.ant.mcp-app" => { "csp" => "default-src 'self'" } }
      resource_template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "template_with_meta",
        meta: meta,
      )

      assert_equal meta, resource_template.to_h[:_meta]
    end

    test "#to_h omits annotations when nil" do
      resource_template = ResourceTemplate.new(uri_template: "file:///{path}", name: "template_without_annotations")

      refute resource_template.to_h.key?(:annotations)
    end

    test "#to_h includes annotations when present" do
      annotations = Annotations.new(audience: ["user"], priority: 0.8, last_modified: "2025-01-12T15:00:58Z")
      resource_template = ResourceTemplate.new(
        uri_template: "file:///{path}",
        name: "template_with_annotations",
        annotations: annotations,
      )

      expected = { audience: ["user"], priority: 0.8, lastModified: "2025-01-12T15:00:58Z" }
      assert_equal expected, resource_template.to_h[:annotations]
    end

    class UserProfileTemplate < ResourceTemplate
      uri_template "users://{user_id}/profile"
      title "User Profile"
      description "profile for a user"
      mime_type "application/json"

      class << self
        def contents(user_id:)
          [Resource::TextContents.new(uri: "users://#{user_id}/profile", mime_type: mime_type, text: "profile of #{user_id}")]
        end
      end
    end

    test "class-based .to_h emits the same keys as the equivalent instance" do
      instance = ResourceTemplate.new(
        uri_template: "users://{user_id}/profile",
        name: "user_profile_template",
        title: "User Profile",
        description: "profile for a user",
        mime_type: "application/json",
      )

      assert_equal instance.to_h, UserProfileTemplate.to_h
    end

    test "class-based name defaults to the snake_cased class name" do
      assert_equal "user_profile_template", UserProfileTemplate.name_value
    end

    test "explicit resource_template_name wins over the class name" do
      template_class = Class.new(UserProfileTemplate) do
        resource_template_name "custom_template"
      end

      assert_equal "custom_template", template_class.resource_template_name
      assert_equal "custom_template", template_class.name_value
    end

    test "subclasses of a configured class start clean" do
      subclass = Class.new(UserProfileTemplate)

      assert_nil subclass.uri_template
      assert_nil subclass.title
      assert_nil subclass.description
      assert_nil subclass.mime_type
    end

    test ".contents raises NotImplementedError unless implemented" do
      template_class = Class.new(ResourceTemplate)

      assert_raises(NotImplementedError) { template_class.contents(user_id: "42") }
    end

    test ".match_uri extracts a single template variable" do
      assert_equal({ user_id: "42" }, UserProfileTemplate.match_uri("users://42/profile"))
    end

    test ".match_uri extracts multiple template variables" do
      template_class = Class.new(ResourceTemplate) do
        uri_template "repos://{owner}/{repo}"
      end

      assert_equal({ owner: "octo", repo: "sdk" }, template_class.match_uri("repos://octo/sdk"))
    end

    test ".match_uri returns an empty hash for an exact match without variables" do
      template_class = Class.new(ResourceTemplate) do
        uri_template "config://app"
      end

      assert_equal({}, template_class.match_uri("config://app"))
    end

    test ".match_uri returns nil when the URI does not match" do
      assert_nil UserProfileTemplate.match_uri("users://42/settings")
      assert_nil UserProfileTemplate.match_uri("posts://42/profile")
    end

    test ".match_uri variables do not cross path separators" do
      assert_nil UserProfileTemplate.match_uri("users://42/extra/profile")
    end

    test ".match_uri returns nil when uri_template is not set" do
      template_class = Class.new(ResourceTemplate)

      assert_nil template_class.match_uri("users://42/profile")
    end

    test ".match_uri escapes regex metacharacters in literal parts" do
      template_class = Class.new(ResourceTemplate) do
        uri_template "file:///data.v1/{name}"
      end

      assert_equal({ name: "foo" }, template_class.match_uri("file:///data.v1/foo"))
      assert_nil template_class.match_uri("file:///dataXv1/foo")
    end

    test ".match_uri treats unsupported RFC 6570 operators as literals" do
      template_class = Class.new(ResourceTemplate) do
        uri_template "search://items{?query}"
      end

      assert_nil template_class.match_uri("search://items?query=foo")
      assert_equal({}, template_class.match_uri("search://items{?query}"))
    end

    test "re-setting uri_template invalidates the compiled pattern" do
      template_class = Class.new(ResourceTemplate) do
        uri_template "old://{id}"
      end
      assert_equal({ id: "1" }, template_class.match_uri("old://1"))

      template_class.uri_template("new://{id}")

      assert_nil template_class.match_uri("old://1")
      assert_equal({ id: "2" }, template_class.match_uri("new://2"))
    end

    test ".define creates a template class whose block implements contents" do
      template_class = ResourceTemplate.define(
        uri_template: "items://{item_id}",
        name: "item_template",
        mime_type: "text/plain",
      ) do |item_id:|
        [Resource::TextContents.new(uri: "items://#{item_id}", mime_type: mime_type, text: "item #{item_id}")]
      end

      assert_equal "items://{item_id}", template_class.uri_template
      assert_equal "item_template", template_class.name_value

      contents = template_class.contents(item_id: "7")
      assert_equal 1, contents.size
      assert_equal "item 7", contents.first.text
    end
  end
end
