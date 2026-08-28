---
layout: default
title: Multi Round-Trip Requests
nav_order: 4
redirect_from:
  - /client/multi-round-trip-results/
---

# Multi Round-Trip Requests

MCP 2026-07-28 replaces in-flight server-to-client requests with Multi Round-Trip Requests (SEP-2322): instead of issuing `sampling/createMessage`, `roots/list`,
or `elicitation/create` while a request is being processed, a server may answer with a result whose `resultType` is `"input_required"`, carrying an `inputRequests` map
and an opaque `requestState`; the client fulfills the requests and re-issues the original request with `inputResponses` and the echoed `requestState`.

## Automatic Driving

The Ruby client drives such results automatically: once a handler is registered through `on_elicitation`, `on_sampling`, or `on_roots`, the `call_tool`, `get_prompt`,
and `read_resource` methods fulfill the embedded requests and re-issue the original request with `inputResponses` plus the echoed `requestState`, capped at `input_required_max_rounds`
(10 by default, matching the TypeScript and Python SDKs).

```ruby
client = MCP::Client.new(transport: transport)
client.connect(capabilities: { elicitation: { form: {} } })

client.on_elicitation do |params|
  { action: "accept", content: { name: "Alice" } }
end

# The input_required round trips are driven automatically; this returns the final result.
response = client.call_tool(name: "collect_name", arguments: {})
```

Declare the capabilities matching the registered handlers on `connect`: a server embeds only the request kinds
the client declared.

## Manual Driving

Without a matching handler, `MCP::Client::InputRequiredError` is raised instead of returning the result as if it were final;
the error exposes `input_requests`, `request_state`, and the raw `result` for manual driving via the `input_responses:` and `request_state:` keywords:

```ruby
begin
  client.call_tool(name: "collect_name", arguments: {})
rescue MCP::Client::InputRequiredError => error
  answers = error.input_requests.transform_values { |request| answer_for(request) }

  client.call_tool(
    name: "collect_name",
    arguments: {},
    input_responses: answers,
    request_state: error.request_state,
  )
end
```

`MCP::ResultType::COMPLETE` and `MCP::ResultType::INPUT_REQUIRED` are provided for forward compatibility.
Servers on legacy protocol versions never send `resultType`, so existing behavior is unchanged.

## Server Side

Authoring `input_required` results with `InputRequiredResult`, securing `requestState`, `resultType` stamping, and the legacy fulfillment
shim that serves pre-2026 clients are documented on the server [Multi Round-Trip Requests](/server/mrtr/) page.
