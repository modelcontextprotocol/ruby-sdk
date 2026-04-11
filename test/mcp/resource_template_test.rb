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
  end
end
