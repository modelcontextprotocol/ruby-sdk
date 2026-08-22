---
layout: default
title: Multi Round-Trip Requests
nav_order: 10
redirect_from:
  - /server/multi-round-trip-results/
---

# Multi Round-Trip Requests

The [modern lifecycle](/server/discover/#the-stateless-modern-lifecycle) (MCP 2026-07-28) forbids server-initiated requests. Instead, per SEP-2322, a `tools/call`, `prompts/get`, or `resources/read` handler that
opts in to [`server_context:`](/server/server-context/) may return `MCP::Server::InputRequiredResult.new(input_requests:, request_state:)` to ask the client for
additional input (`elicitation/create`, `sampling/createMessage`, or `roots/list` shapes):

```ruby
class GreetingTool < MCP::Tool
  description "Greets the user by name"

  def self.call(server_context:, **_args)
    response = server_context.input_response("user_name")

    unless response
      return MCP::Server::InputRequiredResult.new(
        input_requests: {
          user_name: {
            method: "elicitation/create",
            params: {
              message: "What is your name?",
              requestedSchema: {
                type: "object",
                properties: { name: { type: "string" } },
                required: ["name"],
              },
            },
          },
        },
      )
    end

    MCP::Tool::Response.new([{ type: "text", text: "Hello, #{response.dig(:content, :name)}!" }])
  end
end
```

## Deterministic Replay

On the retried request the handler re-runs from the start and reads the answers via
`server_context.input_responses` / `server_context.input_response(key)` and the echoed opaque `server_context.request_state`
(deterministic replay; the server holds no memory between rounds). The server returns `-32021`
when an embedded request needs a client capability the request did not declare.

## Securing `requestState`

The echoed `requestState` arrives as client-controlled input: pass `MCP::Server::RequestStateSecurity.new(key:)` (a 32-byte key) via
`Server.new(request_state_security:)` to have it sealed with AES-256-GCM and bound to a TTL plus the originating method, target, and arguments,
all transparently to handlers. Multi-process deployments must share the key across workers; without `request_state_security:` the state crosses
the wire exactly as the handler wrote it and protecting it is the handler author's responsibility.

```ruby
server = MCP::Server.new(
  name: "my_server",
  tools: [GreetingTool],
  request_state_security: MCP::Server::RequestStateSecurity.new(key: ENV.fetch("MCP_REQUEST_STATE_KEY")),
)
```

## `resultType` Stamping

SEP-2322 also makes `resultType` a required member of every result a 2026-07-28 server returns. The server stamps `resultType: "complete"`
on all results of requests carrying the modern `_meta` envelope (and on `server/discover` results), while results that already carry
a discriminator (`"input_required"`, the tasks extension's `"task"`) keep it. Legacy results stay unstamped, and clients treat an absent
`resultType` as `"complete"` per the spec.

## Legacy Clients

Handlers written in the 2026 style serve pre-2026 clients too: when a `tools/call`, `prompts/get`, or `resources/read` handler returns
an `InputRequiredResult` on the legacy wire, the server fulfills it in place of the client's driver. Each `inputRequests` entry is sent
as the equivalent real server-to-client request (`elicitation/create`, `sampling/createMessage`, `roots/list`), associated with
the originating request per SEP-2260; the answers are collected under the same keys, and the handler re-runs with
`server_context.input_responses` populated and the raw `requestState` echoed, the same deterministic replay contract
the modern client driver follows. The shim is on by default (matching the TypeScript SDK) and capped at 8 rounds;
`MCP::Server.new(input_required_legacy_shim: false)` restores the strict rejection of `input_required` results on legacy requests.

## Client Side

`call_tool`, `get_prompt`, and `read_resource` drive `input_required` results automatically once the matching handlers are registered;
see the client [Multi Round-Trip Requests](/client/mrtr/) page.
