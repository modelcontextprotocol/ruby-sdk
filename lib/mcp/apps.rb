# frozen_string_literal: true

module MCP
  # Server-side helpers for the MCP Apps extension (SEP-1865, Extensions Track, Final):
  # interactive user interfaces delivered as `ui://` HTML template resources that hosts
  # render for tool results. The extension is negotiated per SEP-2133 through
  # `capabilities.extensions` on both sides; a server declares {EXTENSION_ID}, registers
  # UI templates as ordinary resources, and links tools to templates via `_meta`.
  #
  # Everything else defined by the extension (the sandboxed iframe, the `ui/*`
  # postMessage bridge methods, consent for UI-initiated calls) is HOST responsibility:
  # a server only ever receives ordinary `resources/read` and `tools/call` requests.
  #
  # Because the extension is optional, a UI-enabled tool MUST still return a meaningful
  # text-only result for clients that did not declare the capability;
  # use {Apps.client_supports?} to branch.
  #
  # @example Declaring an Apps-enabled server
  #   capabilities = MCP::Server::Capabilities.new
  #   capabilities.support_tools
  #   capabilities.support_resources
  #   capabilities.support_extensions(MCP::Apps.capability)
  #   server = MCP::Server.new(
  #     name: "weather_server",
  #     capabilities: capabilities,
  #     resources: [MCP::Apps.ui_resource(uri: "ui://weather-server/dashboard", name: "weather_dashboard")],
  #   )
  #   server.define_tool(
  #     name: "get_weather",
  #     meta: MCP::Apps.tool_meta(resource_uri: "ui://weather-server/dashboard"),
  #   ) { |server_context:|
  #     ...
  #   }
  #
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx
  module Apps
    # Reverse-DNS extension identifier (note: `/ui`, not `/apps`), shared wire vocabulary with
    # the reference `@modelcontextprotocol/ext-apps` package and the Python SDK's `Apps` extension.
    EXTENSION_ID = "io.modelcontextprotocol/ui"
    # UI template resources MUST use this parameterized MIME type.
    RESOURCE_MIME_TYPE = "text/html;profile=mcp-app"
    # UI template resource URIs MUST use this scheme.
    URI_SCHEME = "ui://"
    # Legacy flat `_meta` key linking a tool to its template; the canonical shape is
    # the nested `_meta.ui.resourceUri`. {Apps.tool_meta} can emit both.
    RESOURCE_URI_META_KEY = "ui/resourceUri"

    extend self

    # The `capabilities.extensions` fragment advertising Apps support. Pass to
    # `MCP::Server::Capabilities.new(extensions: ...)` or `support_extensions(...)`,
    # or merge into a client's `connect(capabilities: { extensions: ... })`.
    def capability(mime_types: [RESOURCE_MIME_TYPE])
      { EXTENSION_ID => { mimeTypes: mime_types } }
    end

    # Builds an `MCP::Resource` for a UI template, enforcing the spec's MUSTs:
    # a `ui://` URI and the `text/html;profile=mcp-app` MIME type by default.
    def ui_resource(uri:, name:, mime_type: RESOURCE_MIME_TYPE, **rest)
      unless uri.is_a?(String) && uri.start_with?(URI_SCHEME)
        raise ArgumentError, "MCP Apps template URIs must start with #{URI_SCHEME.inspect} (got #{uri.inspect})"
      end

      Resource.new(uri: uri, name: name, mime_type: mime_type, **rest)
    end

    # Builds the tool `_meta` linking a tool to its UI template, merged non-destructively into
    # caller-supplied `meta`. `visibility` restricts who sees the tool (an array of `"model"` / `"app"`).
    # `legacy: true` also writes the flat `"ui/resourceUri"` alias, matching the reference server helper
    # that keeps both key shapes in sync for older hosts.
    def tool_meta(resource_uri:, visibility: nil, meta: nil, legacy: false)
      unless resource_uri.is_a?(String) && resource_uri.start_with?(URI_SCHEME)
        raise ArgumentError, "resource_uri must start with #{URI_SCHEME.inspect} (got #{resource_uri.inspect})"
      end

      ui_entry = { resourceUri: resource_uri }
      ui_entry[:visibility] = visibility if visibility

      merged = (meta || {}).merge(ui: ui_entry)
      merged[RESOURCE_URI_META_KEY.to_sym] = resource_uri if legacy
      merged
    end

    # Whether the client declared Apps support for `mime_type` in its `capabilities.extensions`
    # (symbol or string keys). UI-enabled tools use this to fall back to a text-only result for
    # clients without the extension.
    def client_supports?(client_capabilities, mime_type: RESOURCE_MIME_TYPE)
      extensions = read_key(client_capabilities, :extensions)
      declaration = read_key(extensions, EXTENSION_ID)
      return false unless declaration.is_a?(Hash)

      mime_types = read_key(declaration, :mimeTypes)

      # A declaration without mimeTypes advertises the extension without narrowing.
      return true if mime_types.nil?

      mime_types.is_a?(Array) && mime_types.include?(mime_type)
    end

    private

    def read_key(hash, key)
      return unless hash.is_a?(Hash)

      value = hash[key.to_sym]
      value.nil? ? hash[key.to_s] : value
    end
  end
end
