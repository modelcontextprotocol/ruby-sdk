---
layout: default
title: MCP Apps
nav_order: 3
---

# MCP Apps

MCP Apps (SEP-1865) is a Final extension (negotiated via [Capability Extensions](/extensions/capability-extensions/)) that lets a server ship interactive
HTML user interfaces which the host renders for tool results. On the server side the extension is a thin convention,
and `MCP::Apps` provides the vocabulary and helpers:

```ruby
capabilities = MCP::Server::Capabilities.new
capabilities.support_tools
capabilities.support_resources
capabilities.support_extensions(MCP::Apps.capability) # { "io.modelcontextprotocol/ui" => { mimeTypes: [...] } }

server = MCP::Server.new(
  name: "weather_server",
  capabilities: capabilities,
  # UI templates are ordinary resources with a `ui://` URI and the `text/html;profile=mcp-app` MIME type.
  resources: [MCP::Apps.ui_resource(uri: "ui://weather-server/dashboard", name: "weather_dashboard")],
)

server.resources_read_handler do |params|
  [{ uri: params[:uri], mimeType: MCP::Apps::RESOURCE_MIME_TYPE, text: "<html>...</html>" }]
end

# Link the tool to its template via `_meta.ui.resourceUri` (pass `legacy: true` to also
# emit the older flat `"ui/resourceUri"` alias for hosts that predate the Final spec).
server.define_tool(
  name: "get_weather",
  meta: MCP::Apps.tool_meta(resource_uri: "ui://weather-server/dashboard"),
) do |server_context:|
  # The extension is optional: always return a meaningful text result, and use
  # `MCP::Apps.client_supports?` when UI-capable clients should get richer structured content.
  MCP::Apps.client_supports?(server_context.client_capabilities) # => true when the host declared the extension
  MCP::Tool::Response.new([{ type: "text", text: "Sunny, 22 degrees Celsius" }])
end
```

`MCP::Apps.tool_meta` also accepts `visibility:` (an array of `"model"` / `"app"`) to restrict who sees the tool,
and merges non-destructively into caller-supplied `meta:`.

Everything else the extension defines (the sandboxed iframe, the `ui/*` `postMessage` bridge, consent for UI-initiated actions)
is the HOST's responsibility; a server only ever receives ordinary `resources/read` and `tools/call` requests.
See the [MCP Apps specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).
