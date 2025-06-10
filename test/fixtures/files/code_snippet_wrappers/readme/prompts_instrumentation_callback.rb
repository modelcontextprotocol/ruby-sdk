# frozen_string_literal: true

require "mcp"
require_relative "code_snippet"

puts MCP::Server.new.handle_json({ jsonrpc: "2.0", id: "1", method: "ping" }.to_json)
