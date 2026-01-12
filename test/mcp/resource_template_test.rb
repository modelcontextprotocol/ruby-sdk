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
  end
end
