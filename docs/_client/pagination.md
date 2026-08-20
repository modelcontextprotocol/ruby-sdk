---
layout: default
title: Pagination
nav_order: 7
---

# Pagination

Servers may paginate `tools/list`, `prompts/list`, `resources/list`, and `resources/templates/list` responses
per the [MCP pagination utility](https://modelcontextprotocol.io/specification/latest/server/utilities/pagination).
Cursor tokens are opaque to clients: the server decides page size, and the client follows `nextCursor` until the server omits it.

## Iterating Pages

`MCP::Client` exposes `list_tools`, `list_prompts`, `list_resources`, and `list_resource_templates`.
**Each call issues exactly one `*/list` JSON-RPC request and returns exactly one page** - not the full collection.
The returned result object (`MCP::Client::ListToolsResult` etc.) exposes the page items and the next cursor
as method accessors; a `meta` accessor also mirrors the response's `_meta` field:

```ruby
client = MCP::Client.new(transport: transport)

cursor = nil
loop do
  page = client.list_tools(cursor: cursor)
  page.tools.each { |tool| process(tool) }
  cursor = page.next_cursor
  break unless cursor
end
```

The same pattern applies to `list_prompts` (`page.prompts`), `list_resources` (`page.resources`), and
`list_resource_templates` (`page.resource_templates`). `next_cursor` is `nil` on the final page.

Because a single call returns a single page, how many items come back depends on the server's `page_size` configuration:

| Server `page_size` | `client.list_tools(cursor: nil)`                                    |
|--------------------|---------------------------------------------------------------------|
| Not set (default)  | Returns every item in one response. `next_cursor` is `nil`.         |
| Set to `N`         | Returns the first `N` items. `next_cursor` is set for continuation. |

If your application needs the complete collection regardless of how the server is configured, either loop on
`next_cursor` as shown above, or use the whole-collection methods described below.

## Fetching the Complete Collection

`client.tools`, `client.resources`, `client.resource_templates`, and `client.prompts` auto-iterate
through all pages and return a plain array of items, guaranteeing the full collection regardless
of the server's `page_size` setting. When a server paginates, they issue multiple JSON-RPC round
trips per call. Two guards keep that loop finite: it stops when the server returns a `nextCursor`
it has already sent, and it stops after `max_pages` pages.

```ruby
tools = client.tools # => Array<MCP::Client::Tool> of every tool on the server.
```

`MCP::Client.new` accepts an optional `max_pages:` keyword that caps how many pages these methods
will walk. It defaults to `1_000`; a server that keeps offering a fresh `nextCursor` past that
point raises `MCP::Client::PaginationLimitError` rather than being followed indefinitely. Raise it
if you legitimately expect more pages than that.

Use these when you want the complete list; use `list_tools(cursor:)` etc. when you need
fine-grained iteration (e.g. to stream-process pages without loading everything into memory).

## Cache Hints

Per SEP-2549, list and read results can carry cache hints telling clients how long a result stays fresh (`ttlMs`)
and whether shared intermediaries may cache it (`cacheScope`); see
[List Result Caching](/server/pagination/#list-result-caching) on the server page for how they are emitted.
On the client, the values are surfaced on the paginated result structs as `ttl_ms` and `cache_scope`:

```ruby
page = client.list_tools
page.ttl_ms      # => 60000 (nil when the server sent no hint)
page.cache_scope # => "private"
```

## Server Side

Enabling pagination with `page_size:` is documented on the server [Pagination](/server/pagination/) page.
