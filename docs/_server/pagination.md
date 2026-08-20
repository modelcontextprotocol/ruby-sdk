---
layout: default
title: Pagination
nav_order: 18
---

# Pagination

The MCP Ruby SDK supports [pagination](https://modelcontextprotocol.io/specification/latest/server/utilities/pagination)
for list operations that may return large result sets. Pagination uses string cursor tokens carrying a zero-based offset,
treated as opaque by clients: the server decides page size, and the client follows `nextCursor` until the server omits it.

Pagination applies to `tools/list`, `prompts/list`, `resources/list`, and `resources/templates/list`,
including lists produced by a custom `resources_list_handler`.

## Enabling Pagination

Pass `page_size:` to `MCP::Server.new` to split list responses into pages. When `page_size` is omitted (the default),
list responses contain all items in a single response, preserving the pre-pagination behavior.

```ruby
server = MCP::Server.new(
  name: "my_server",
  tools: tools,
  page_size: 50,
)
```

When `page_size` is set, list responses include a `nextCursor` field whenever more pages are available:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      { "name": "example_tool" }
    ],
    "nextCursor": "50"
  }
}
```

Invalid cursors (e.g. non-numeric, negative, or out-of-range) are rejected with JSON-RPC error code `-32602 (Invalid params)` per the MCP specification.

## List Result Caching

Per SEP-2549, list and read results can carry cache hints telling clients how long a result stays fresh (`ttlMs`, max-age semantics in milliseconds;
`0` means do not cache) and whether shared intermediaries may cache it (`cacheScope`: `"public"` or `"private"`).

Emission is opt-in: pass `ttl_ms:` and/or `cache_scope:` to `MCP::Server.new` and both fields are added to `tools/list`, `prompts/list`, `resources/list`,
`resources/templates/list`, and `resources/read` results (a missing field is filled with the defaults `ttlMs: 0` / `cacheScope: "private"`,
the scope that keeps a potentially user-dependent result out of shared caches).
When neither is set, responses are serialized exactly as before.
The 2026-07-28 revision makes both hints required on these results, so on requests carrying the modern `_meta` envelope
the server always emits them, filling unset values with the same defaults; legacy protocol versions keep the opt-in behavior.

```ruby
server = MCP::Server.new(
  name: "my_server",
  tools: tools,
  ttl_ms: 60_000,        # results stay fresh for one minute
  cache_scope: "private", # only the requesting client may cache them
)
```

A `resources_read_handler` can override the hints per result by returning a full result hash instead of bare contents:

```ruby
server.resources_read_handler do |params|
  { contents: [{ uri: params[:uri], mimeType: "text/plain", text: "..." }], ttlMs: 5_000 }
end
```

## Client Side

Iterating pages, fetching whole collections with the `max_pages` guard, and reading the cache hints
on the result structs are documented on the client [Pagination](/client/pagination/) page.
