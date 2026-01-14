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
  end
end
