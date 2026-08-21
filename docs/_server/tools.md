---
layout: default
title: Tools
nav_order: 4
---

# Tools

MCP spec includes [Tools](https://modelcontextprotocol.io/specification/latest/server/tools) which provide functionality to LLM apps.

## Defining Tools

This gem provides a `MCP::Tool` class that can be used to create tools in three ways.

### 1. As a class definition

Subclass `MCP::Tool` and declare the metadata with class-level helpers; `call` implements the tool:

```ruby
class MyTool < MCP::Tool
  title "My Tool"
  description "This tool performs specific functionality..."
  input_schema(
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  )
  output_schema(
    properties: {
      result: { type: "string" },
      success: { type: "boolean" },
      timestamp: { type: "string", format: "date-time" }
    },
    required: ["result", "success", "timestamp"]
  )
  annotations(
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false,
    title: "My Tool"
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: "text", text: "OK" }])
  end
end

tool = MyTool
```

### 2. Using the `MCP::Tool.define` method

`MCP::Tool.define` builds a tool from keyword arguments, with the block as its implementation:

```ruby
tool = MCP::Tool.define(
  name: "my_tool",
  title: "My Tool",
  description: "This tool performs specific functionality...",
  annotations: {
    read_only_hint: true,
    title: "My Tool"
  }
) do |args, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: "OK" }])
end
```

### 3. Using the `MCP::Server#define_tool` method

`MCP::Server#define_tool` registers the tool directly on a server instance:

```ruby
server = MCP::Server.new
server.define_tool(
  name: "my_tool",
  description: "This tool performs specific functionality...",
  annotations: {
    title: "My Tool",
    read_only_hint: true
  }
) do |args, server_context:|
  Tool::Response.new([{ type: "text", text: "OK" }])
end
```

The [`server_context`](/server/server-context/) parameter is the `server_context` passed into the server and can be used to pass per request information,
e.g. around authentication state.

## Tool argument keys

Tool arguments are delivered as a `Hash` whose keys are Ruby symbols at every nesting level, including nested objects
and objects inside arrays. The transports parse incoming JSON with `JSON.parse(..., symbolize_names: true)`,
so by the time a tool runs, a wire payload such as `{"payload": {"subject": "greet"}}` arrives as `{ payload: { subject: "greet" } }`.

This means top-level values are bound through keyword arguments (`def call(message:, payload: nil, server_context:)`),
and nested objects must be read with symbol keys:

```ruby
class ExampleTool < MCP::Tool
  description "Echoes a nested argument"
  input_schema(
    properties: {
      message: { type: "string" },
      payload: {
        type: "object",
        properties: {
          subject: { type: "string" },
        }
      }
    },
    required: ["message"]
  )

  def self.call(message:, payload: nil, server_context:)
    subject = payload && payload[:subject] # symbol key, not payload["subject"]
    MCP::Tool::Response.new([{
      type: "text",
      text: "Message: #{message}; subject: #{subject}"
    }])
  end
end
```

Reading a nested value with a string key (`payload["subject"]`) returns `nil`. This is a Ruby-specific contract:
Top-level keyword arguments require symbol keys, and parsing JSON with `symbolize_names: true` symbolizes nested objects too.

Calling a tool directly in a test with `MyTool.call(payload: { "subject" => "greet" }, server_context: nil)` passes string keys
that a transport never delivers, so string-key access can pass tests yet fail against a real client.
Exercise a tool under the delivered shape by round-tripping the arguments through JSON the same way a transport does:

```ruby
delivered = JSON.parse(JSON.generate(arguments), symbolize_names: true)
MyTool.call(**delivered, server_context: nil)
```

## Tool Annotations

Tools can include annotations that provide additional metadata about their behavior. The following annotations are supported:

- `destructive_hint`: Indicates if the tool performs destructive operations. Defaults to true
- `idempotent_hint`: Indicates if the tool's operations are idempotent. Defaults to false
- `open_world_hint`: Indicates if the tool operates in an open world context. Defaults to true
- `read_only_hint`: Indicates if the tool only reads data (doesn't modify state). Defaults to false
- `title`: A human-readable title for the tool

Annotations can be set either through the class definition using the `annotations` class method or when defining a tool using the `define` method.

{: .note }
> This **Tool Annotations** feature is supported starting from `protocol_version: '2025-03-26'`.

## Tool Output Schemas

Tools can optionally define an `output_schema` to specify the expected structure of their results. This works similarly to how `input_schema` is defined and can be used in three ways.

### 1. Class definition with `output_schema`

Declare the schema with the `output_schema` class helper, alongside `input_schema`:

```ruby
class WeatherTool < MCP::Tool
  tool_name "get_weather"
  description "Get current weather for a location"

  input_schema(
    properties: {
      location: { type: "string" },
      units: { type: "string", enum: ["celsius", "fahrenheit"] }
    },
    required: ["location"]
  )

  output_schema(
    properties: {
      temperature: { type: "number" },
      condition: { type: "string" },
      humidity: { type: "integer" }
    },
    required: ["temperature", "condition", "humidity"]
  )

  def self.call(location:, units: "celsius", server_context:)
    # Call weather API and structure the response
    api_response = WeatherAPI.fetch(location, units)
    weather_data = {
      temperature: api_response.temp,
      condition: api_response.description,
      humidity: api_response.humidity_percent
    }

    output_schema.validate_result(weather_data)

    MCP::Tool::Response.new([{
      type: "text",
      text: weather_data.to_json
    }])
  end
end
```

### 2. Using `Tool.define` with `output_schema`

Pass the schema as the `output_schema:` keyword argument:

```ruby
tool = MCP::Tool.define(
  name: "calculate_stats",
  description: "Calculate statistics for a dataset",
  input_schema: {
    properties: {
      numbers: { type: "array", items: { type: "number" } }
    },
    required: ["numbers"]
  },
  output_schema: {
    properties: {
      mean: { type: "number" },
      median: { type: "number" },
      count: { type: "integer" }
    },
    required: ["mean", "median", "count"]
  }
) do |args, server_context:|
  # Calculate statistics and validate against schema
  MCP::Tool::Response.new([{ type: "text", text: "Statistics calculated" }])
end
```

### 3. Using `OutputSchema` objects

Construct an `MCP::Tool::OutputSchema` object explicitly:

```ruby
class DataTool < MCP::Tool
  output_schema MCP::Tool::OutputSchema.new(
    properties: {
      success: { type: "boolean" },
      data: { type: "object" }
    },
    required: ["success"]
  )
end
```

Output schema may also describe an array of objects:

```ruby
class WeatherTool < MCP::Tool
  output_schema(
    type: "array",
    items: {
      properties: {
        temperature: { type: "number" },
        condition: { type: "string" },
        humidity: { type: "integer" }
      },
      required: ["temperature", "condition", "humidity"]
    }
  )
end
```

Please note: in this case, you must provide `type: "array"`. The default type for output schemas is `object`,
applied only when the schema declares no root keyword (`type`, `$ref`, `oneOf`, `anyOf`, `allOf`, `not`, `if`, `const`, `enum`).

Per SEP-2106, an output schema may be any valid JSON Schema 2020-12 document, including a primitive root
(`{ type: "string" }`) or a root-level composition:

```ruby
class FlexibleTool < MCP::Tool
  output_schema(
    oneOf: [
      { type: "string" },
      { type: "array", items: { type: "number" } }
    ]
  )
end
```

Input schemas keep `type: "object"` at the root but accept the full 2020-12 vocabulary below it
(`$defs`/`$ref`, `oneOf`/`anyOf`/`allOf`/`not`, `if`/`then`/`else`). Two resource bounds apply to
all tool schemas: only same-document `$ref`s (starting with `#`) are accepted, and documents are
capped at `MCP::Tool::Schema::MAX_SCHEMA_DEPTH` nesting levels and `MCP::Tool::Schema::MAX_SUBSCHEMA_COUNT` subschema objects;
violations raise `ArgumentError` at construction time.

MCP spec for the [Output Schema](https://modelcontextprotocol.io/specification/latest/server/tools#output-schema) specifies that:

- **Server Validation**: Servers MUST provide structured results that conform to the output schema
- **Client Validation**: Clients SHOULD validate structured results against the output schema
- **Better Integration**: Enables strict schema validation, type information, and improved developer experience
- **Backward Compatibility**: Tools returning structured content SHOULD also include serialized JSON in a TextContent block

The output schema follows standard JSON Schema format and helps ensure consistent data exchange between MCP servers and clients.

By default, server-side validation of tool results against `output_schema` is disabled for backwards compatibility.
To validate successful tool responses, enable `validate_tool_call_results` on the server [configuration](/server/configuration/):

```ruby
configuration = MCP::Configuration.new(validate_tool_call_results: true)
server = MCP::Server.new(
  name: "example_server",
  tools: [WeatherTool],
  configuration: configuration
)
```

When enabled, successful tool responses for tools with an `output_schema` must include `structured_content` that conforms to the schema.
Error responses are not validated against the output schema.

## Tool Responses with Structured Content

Tools can return structured data alongside text content using the `structured_content` parameter.

The structured content will be included in the JSON-RPC response as the `structuredContent` field.

Per SEP-2106, `structured_content` may be any JSON value, not only an object. When a tool returns a non-object value (e.g. an array)
without providing any content blocks, the server automatically mirrors it into `content` as serialized JSON text so older clients
that only read `content` still receive the data.

```ruby
class WeatherTool < MCP::Tool
  description "Get current weather and return structured data"

  def self.call(location:, units: "celsius", server_context:)
    # Call weather API and structure the response
    api_response = WeatherAPI.fetch(location, units)
    weather_data = {
      temperature: api_response.temp,
      condition: api_response.description,
      humidity: api_response.humidity_percent
    }

    output_schema.validate_result(weather_data)

    MCP::Tool::Response.new(
      [{
        type: "text",
        text: weather_data.to_json
      }],
      structured_content: weather_data
    )
  end
end
```

## Tool Responses with Errors

Tools can return error information alongside text content using the `error` parameter.

The error will be included in the JSON-RPC response as the `isError` field.

```ruby
class WeatherTool < MCP::Tool
  description "Get current weather and return structured data"

  def self.call(server_context:)
    # Do something here
    content = {}

    MCP::Tool::Response.new(
      [{
        type: "text",
        text: content.to_json
      }],
      structured_content: content,
      error: true
    )
  end
end
```

## Tool Responses with Image, Audio, and Embedded Resources

Tool responses are not limited to text. The `MCP::Content` module provides `Image`, `Audio`, and `EmbeddedResource` content types,
which serialize to the `image`, `audio`, and `resource` content blocks defined by the MCP spec. Image and audio data is passed as
a base64-encoded string together with its MIME type:

```ruby
class ChartTool < MCP::Tool
  description "Render a chart as a PNG image"

  def self.call(server_context:)
    MCP::Tool::Response.new([
      MCP::Content::Text.new("Here is the rendered chart:").to_h,
      MCP::Content::Image.new(Base64.strict_encode64(render_chart_png), "image/png").to_h,
    ])
  end
end

class SpeechTool < MCP::Tool
  description "Synthesize speech audio"

  def self.call(server_context:)
    MCP::Tool::Response.new([
      MCP::Content::Audio.new(Base64.strict_encode64(synthesize_wav), "audio/wav").to_h,
    ])
  end
end
```

An [embedded resource](/server/resources/) wraps `MCP::Resource::TextContents` or `MCP::Resource::BlobContents`, allowing a tool to return resource contents inline:

```ruby
class ReportTool < MCP::Tool
  description "Return a report as an embedded resource"

  def self.call(server_context:)
    contents = MCP::Resource::TextContents.new(
      uri: "report://monthly",
      mime_type: "application/json",
      text: { total: 42 }.to_json,
    )

    MCP::Tool::Response.new([MCP::Content::EmbeddedResource.new(contents).to_h])
  end
end
```
