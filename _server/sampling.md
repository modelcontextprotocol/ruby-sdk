---
layout: default
title: Sampling
nav_order: 8
---

# Sampling

The Model Context Protocol allows servers to request LLM completions from clients through the `sampling/createMessage` method.
This enables servers to leverage the client's LLM capabilities without needing direct access to AI models.

{: .warning }
> MCP Sampling (`sampling/createMessage`) is deprecated as of protocol version `2026-07-28` (SEP-2577),
> while remaining fully supported under `2025-11-25`. New servers should call LLM provider APIs directly.
> A client declaring the `sampling` capability on a modern connection emits a deprecation warning.

{: .important }
> Per SEP-2260, server-to-client requests (`roots/list`, `sampling/createMessage`, `elicitation/create`) must be associated with
> an originating client request (`ping` is exempt). Use the `server_context` passed to your handler, which stamps the association
> automatically and routes the request onto the originating POST stream on the Streamable HTTP transport. Calling the corresponding
> `ServerSession` methods without `related_request_id:` still works but emits a deprecation warning.

Server-to-client requests are bounded by a timeout on the Streamable HTTP transport; see [Timeouts](/server/elicitation/#timeouts).

## Key Concepts

- **Server-to-Client Request**: Unlike typical MCP methods (client to server), sampling is initiated by the server
- **Client Capability**: Clients must declare `sampling` capability during initialization
- **Tool Support**: When using tools in sampling requests, clients must declare `sampling.tools` capability
- **Human-in-the-Loop**: Clients can implement user approval before forwarding requests to LLMs

## Using Sampling in Tools

Tools that accept a [`server_context:`](/server/server-context/) parameter can call `create_sampling_message` on it.
The request is automatically routed to the correct client session:

```ruby
class SummarizeTool < MCP::Tool
  description "Summarize text using LLM"
  input_schema(
    properties: {
      text: { type: "string" }
    },
    required: ["text"]
  )

  def self.call(text:, server_context:)
    result = server_context.create_sampling_message(
      messages: [
        { role: "user", content: { type: "text", text: "Please summarize: #{text}" } }
      ],
      max_tokens: 500
    )

    MCP::Tool::Response.new([{
      type: "text",
      text: result[:content][:text]
    }])
  end
end

server = MCP::Server.new(name: "my_server", tools: [SummarizeTool])
```

## Parameters

Required:

- `messages:` (Array) - Array of message objects with `role` and `content`
- `max_tokens:` (Integer) - Maximum tokens in the response

Optional:

- `system_prompt:` (String) - System prompt for the LLM
- `model_preferences:` (Hash) - Model selection preferences (e.g., `{ intelligencePriority: 0.8 }`)
- `include_context:` (String) - Context inclusion: `"none"`, `"thisServer"`, or `"allServers"` (soft-deprecated)
- `temperature:` (Float) - Sampling temperature
- `stop_sequences:` (Array) - Sequences that stop generation
- `metadata:` (Hash) - Additional metadata
- `tools:` (Array) - Tools available to the LLM (requires `sampling.tools` capability)
- `tool_choice:` (Hash) - Tool selection mode (e.g., `{ mode: "auto" }`)

## Error Handling

- Raises `RuntimeError` if client does not support `sampling` capability
- Raises `RuntimeError` if `tools` are used but client lacks `sampling.tools` capability
- Raises `StandardError` if client returns an error response
