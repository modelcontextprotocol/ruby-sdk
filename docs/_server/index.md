---
layout: default
title: Overview
nav_order: 1
permalink: /server/
redirect_from:
  - /building-servers.html
  - /building-servers/
---

# Building an MCP Server

The `MCP::Server` class is the core component that handles JSON-RPC requests and responses.
It implements the Model Context Protocol specification, handling model context requests and responses.

## Key Features

- Implements JSON-RPC 2.0 message handling
- Supports protocol initialization and capability negotiation
- Manages tool registration and invocation
- Supports prompt registration and execution
- Supports resource registration and retrieval
- Supports stdio and Streamable HTTP (including SSE) transports
- Supports notifications for list changes (tools, prompts, resources)
- Supports roots (server-to-client filesystem boundary queries; deprecated as of 2026-07-28)
- Supports sampling (server-to-client LLM completion requests; deprecated as of 2026-07-28)
- Supports cursor-based pagination for list operations
- Supports cancellation of in-flight requests on both server and client (notifications/cancelled)

## Supported Methods

- `initialize` - Initializes the protocol and returns server capabilities
- `server/discover` - Sessionless capability discovery (MCP 2026-07-28, SEP-2575): returns the server's capabilities
  before `initialize` and without an `Mcp-Session-Id`, and anchors the stateless modern lifecycle; see [Discovery](/server/discover/)
- `subscriptions/listen` - Long-lived notification subscription stream (MCP 2026-07-28, SEP-2575), replacing the legacy HTTP GET
  listening stream; see [Subscriptions](/server/subscriptions/)
- Multi round-trip `input_required` results (MCP 2026-07-28, SEP-2322): handlers return `MCP::Server::InputRequiredResult` to ask
  the client for additional input instead of performing a server-initiated request; see [Multi Round-Trip Requests](/server/mrtr/)
- `ping` - Simple health check
- `logging/setLevel` - Configures the minimum log level for the server (deprecated as of 2026-07-28)
- `tools/list` - Lists all registered tools and their schemas
- `tools/call` - Invokes a specific tool with provided arguments
- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves a specific prompt by name
- `resources/list` - Lists all registered resources and their schemas
- `resources/read` - Retrieves a specific resource by name
- `resources/templates/list` - Lists all registered resource templates and their schemas
- `resources/subscribe` - Subscribes to updates for a specific resource
- `resources/unsubscribe` - Unsubscribes from updates for a specific resource
- `completion/complete` - Returns autocompletion suggestions for prompt arguments and resource URIs
- `roots/list` - Requests filesystem roots from the client (server-to-client; deprecated as of 2026-07-28)
- `sampling/createMessage` - Requests LLM completion from the client (server-to-client; deprecated as of 2026-07-28)
- `elicitation/create` - Requests user input from the client (server-to-client)
