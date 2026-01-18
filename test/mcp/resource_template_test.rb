# frozen_string_literal: true

require "test_helper"

module MCP
  class ResourceTemplateTest < ActiveSupport::TestCase
    test "#to_h returns a hash including uriTemplate, name, description, icons, and mimeType" do
      expected = {
        uriTemplate: "file:///{path}",
        name: "mock_resource_template",
        title: "Mock Template",
        description: "a mock resource template",
        icons: [{ mimeType: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light" }],
        mimeType: "text/plain",
      }
      resource_template = ResourceTemplate.define(
        uri_template: "file:///{path}",
        name: "mock_resource_template",
        title: "Mock Template",
        description: "a mock resource template",
        icons: [Icon.new(mime_type: "image/png", sizes: ["48x48"], src: "https://example.com", theme: "light")],
        mime_type: "text/plain",
      )

      assert_equal(expected, resource_template.to_h)
    end

    test "#to_h does not have `:title` key when title is omitted" do
      resource_template = ResourceTemplate.define(
        uri_template: "file:///{path}",
        name: "mock_template",
        description: "a mock template",
      )
      refute resource_template.to_h.key?(:title)
    end

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

    test "allows declarative definition of resource templates as classes" do
      class MockResourceTemplate < ResourceTemplate
        uri_template "file:///{path}"
        resource_template_name "my_mock_template"
        description "a mock template"
        mime_type "text/plain"

        class << self
          def contents(params:)
            [MCP::Resource::TextContents.new(uri: "file:///#{params[:path]}", mime_type: mime_type, text: "Template Content: #{params[:path]}")]
          end
        end
      end

      template = MockResourceTemplate
      assert_equal "file:///{path}", template.uri_template
      assert_equal "my_mock_template", template.name_value
      assert_equal "a mock template", template.description
      assert_equal "text/plain", template.mime_type

      contents = template.contents(params: { path: "foo" })
      assert_equal 1, contents.size
      assert_instance_of MCP::Resource::TextContents, contents.first
      assert_equal "Template Content: foo", contents.first.text
    end

    test ".define allows definition of resource templates with a block implementing contents" do
      template = ResourceTemplate.define(
        uri_template: "file:///{path}",
        name: "block_template",
      ) do
        class << self
          def contents(params:)
            [MCP::Resource::TextContents.new(uri: "file:///#{params[:path]}", mime_type: "text/plain", text: "Block Template Content")]
          end
        end
      end

      assert_equal "file:///{path}", template.uri_template
      assert_equal "block_template", template.name_value

      contents = template.contents(params: { path: "bar" })
      assert_equal 1, contents.size
      assert_instance_of MCP::Resource::TextContents, contents.first
      assert_equal "Block Template Content", contents.first.text
    end

    test "#contents raises NotImplementedError by default on class" do
      resource_template_class = ResourceTemplate.define(uri_template: "file:///{path}", name: "test")
      assert_raises(NotImplementedError) do
        resource_template_class.contents(params: {})
      end
    end
  end
end
