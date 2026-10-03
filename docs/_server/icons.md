---
layout: default
title: Icons
nav_order: 7
---

# Icons

The MCP spec lets a server attach [icons](https://modelcontextprotocol.io/specification/2025-11-25/basic#icons)
to its own `serverInfo` and to each tool, prompt, resource, and resource template, so a client can show a visual identifier next to them.

## Defining Icons

`MCP::Icon.new` takes the members of the specification's `Icon` type as keyword arguments:

- `src`: the URI of the icon, required. The specification allows an HTTP/HTTPS URL or a `data:` URI with Base64-encoded image data
- `mime_type`: a MIME type such as `"image/png"` or `"image/svg+xml"`, for when the type of the source is missing or generic
- `sizes`: an Array of Strings in `WxH` form, such as `["48x48", "96x96"]`, or `["any"]` for a scalable format like SVG
- `theme`: `"light"` or `"dark"` when the icon is designed for one background

```ruby
icon = MCP::Icon.new(src: "https://example.com/icon.png", mime_type: "image/png", sizes: ["48x48"])
```

Each argument is checked against the type the specification's schema declares, and an `ArgumentError` is raised at definition time for
a `src` that is missing, empty, or not a String, and, when one of the optional arguments is given, for a `sizes` that is not an Array of Strings,
a `mime_type` that is not a String, or a `theme` other than the two values.
What a value means is not checked: the scheme of `src` and the `WxH` form of a size are the server author's to get right, and a client applies
the security rules of the specification (HTTPS or `data:` URIs only, the same origin as the server, size limits) when it fetches an icon.

A Hash is accepted wherever an `MCP::Icon` is and is converted through `MCP::Icon.new`, so it is checked the same way.
Its keys may be Symbols or Strings and may use the keyword names above or the wire name `mimeType`; a Hash with any other key,
or with the same member given twice, is refused.

```ruby
icons = [{ src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48"] }]
```

## Attaching Icons

- `MCP::Server.new(icons: [...])` advertises the icons in `serverInfo`
- Tools and prompts take `icons [...]` in a class definition, or `icons:` on `MCP::Tool.define` and `MCP::Prompt.define`
- Resources and resource templates take `icons [...]` in a class definition, `icons:` on `define`, `icons:` on `MCP::Resource.new`
  and `MCP::ResourceTemplate.new`, and `icons:` on `MCP::Server#define_resource` and `MCP::Server#define_resource_template`

```ruby
class WeatherTool < MCP::Tool
  description "Reports the weather"
  icons [MCP::Icon.new(src: "https://example.com/weather.png", mime_type: "image/png", sizes: ["48x48"])]

  def self.call(server_context:)
    MCP::Tool::Response.new([{ type: "text", text: "sunny" }])
  end
end

prompt = MCP::Prompt.define(
  name: "greeting",
  description: "Greets the user",
  icons: [{ src: "https://example.com/greeting.svg", mimeType: "image/svg+xml", sizes: ["any"] }]
) do |args, server_context:|
  MCP::Prompt::Result.new(
    messages: [
      MCP::Prompt::Message.new(role: "user", content: MCP::Content::Text.new("Hello!"))
    ]
  )
end

server = MCP::Server.new(
  name: "weather_server",
  icons: [
    MCP::Icon.new(src: "https://example.com/server.png", theme: "light"),
    MCP::Icon.new(src: "https://example.com/server-dark.png", theme: "dark")
  ],
  tools: [WeatherTool],
  prompts: [prompt]
)
```

An `icons` of `nil` or `[]` leaves the `icons` member out of the wire representation.

{: .note }
> Icons were added in the 2025-11-25 revision of the specification. The icons in `serverInfo` are sent only when
> the negotiated protocol version is 2025-11-25 or later; the icons of tools, prompts, and resources are listed as defined.
