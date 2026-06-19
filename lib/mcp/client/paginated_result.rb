# frozen_string_literal: true

module MCP
  class Client
    # Result objects returned by `list_tools`, `list_prompts`, `list_resources`, and `list_resource_templates`.
    # Each carries the page items, an optional opaque `next_cursor` string for continuing pagination,
    # and an optional `meta` hash mirroring the MCP `_meta` response field.
    ListToolsResult = Struct.new(:tools, :next_cursor, :meta, keyword_init: true)
    ListPromptsResult = Struct.new(:prompts, :next_cursor, :meta, keyword_init: true)
    ListResourcesResult = Struct.new(:resources, :next_cursor, :meta, keyword_init: true)
    ListResourceTemplatesResult = Struct.new(:resource_templates, :next_cursor, :meta, keyword_init: true)
  end
end
