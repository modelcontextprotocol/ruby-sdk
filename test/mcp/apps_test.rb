# frozen_string_literal: true

require "test_helper"

module MCP
  class AppsTest < ActiveSupport::TestCase
    test "exposes the SEP-1865 wire vocabulary" do
      # The exact strings are shared with the reference ext-apps package and the Python SDK.
      assert_equal "io.modelcontextprotocol/ui", Apps::EXTENSION_ID
      assert_equal "text/html;profile=mcp-app", Apps::RESOURCE_MIME_TYPE
      assert_equal "ui://", Apps::URI_SCHEME
      assert_equal "ui/resourceUri", Apps::RESOURCE_URI_META_KEY
    end

    test ".capability builds the extensions fragment" do
      assert_equal({ "io.modelcontextprotocol/ui" => { mimeTypes: ["text/html;profile=mcp-app"] } }, Apps.capability)
      assert_equal({ "io.modelcontextprotocol/ui" => { mimeTypes: ["text/html"] } }, Apps.capability(mime_types: ["text/html"]))
    end

    test ".ui_resource builds a Resource with the spec defaults and validates the scheme" do
      resource = Apps.ui_resource(uri: "ui://weather/dashboard", name: "dashboard", description: "Weather UI")

      assert_instance_of Resource, resource
      assert_equal "ui://weather/dashboard", resource.uri
      assert_equal "text/html;profile=mcp-app", resource.mime_type
      assert_equal "Weather UI", resource.description
      assert_raises(ArgumentError) do
        Apps.ui_resource(uri: "file:///dashboard.html", name: "dashboard")
      end
    end

    test ".tool_meta links a tool to its template without clobbering caller meta" do
      meta = Apps.tool_meta(
        resource_uri: "ui://weather/dashboard",
        visibility: ["model", "app"],
        meta: { custom: "value" },
      )

      assert_equal({ custom: "value", ui: { resourceUri: "ui://weather/dashboard", visibility: ["model", "app"] } }, meta)
      assert_raises(ArgumentError) do
        Apps.tool_meta(resource_uri: "https://example.com")
      end
    end

    test ".tool_meta emits the legacy flat key when requested" do
      meta = Apps.tool_meta(resource_uri: "ui://weather/dashboard", legacy: true)

      assert_equal "ui://weather/dashboard", meta.dig(:ui, :resourceUri)
      assert_equal "ui://weather/dashboard", meta[:"ui/resourceUri"]
    end

    test ".client_supports? checks the declared extension and mime types" do
      declared = { extensions: { "io.modelcontextprotocol/ui" => { mimeTypes: ["text/html;profile=mcp-app"] } } }
      string_keys = {
        "extensions" => { "io.modelcontextprotocol/ui" => { "mimeTypes" => ["text/html;profile=mcp-app"] } },
      }
      without_mime_types = { extensions: { "io.modelcontextprotocol/ui" => {} } }
      other_mime_type = { extensions: { "io.modelcontextprotocol/ui" => { mimeTypes: ["text/html"] } } }

      assert Apps.client_supports?(declared)
      assert Apps.client_supports?(string_keys)
      assert Apps.client_supports?(without_mime_types)
      refute Apps.client_supports?(other_mime_type)
      refute Apps.client_supports?({})
      refute Apps.client_supports?(nil)
      refute Apps.client_supports?({ extensions: {} })
    end
  end
end
