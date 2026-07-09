# frozen_string_literal: true

module MCP
  class Client
    # Result objects returned by `list_tools`, `list_prompts`, `list_resources`, and `list_resource_templates`.
    # Each carries the page items, an optional opaque `next_cursor` string for continuing pagination,
    # an optional `meta` hash mirroring the MCP `_meta` response field, and the optional SEP-2549
    # cache hints `ttl_ms` (freshness lifetime in milliseconds; 0 means do not cache) and
    # `cache_scope` (`"public"` or `"private"`) mirroring the `ttlMs`/`cacheScope` response fields.
    ListToolsResult = Struct.new(:tools, :next_cursor, :meta, :ttl_ms, :cache_scope, keyword_init: true)
    ListPromptsResult = Struct.new(:prompts, :next_cursor, :meta, :ttl_ms, :cache_scope, keyword_init: true)
    ListResourcesResult = Struct.new(:resources, :next_cursor, :meta, :ttl_ms, :cache_scope, keyword_init: true)
    ListResourceTemplatesResult = Struct.new(:resource_templates, :next_cursor, :meta, :ttl_ms, :cache_scope, keyword_init: true)
  end
end
