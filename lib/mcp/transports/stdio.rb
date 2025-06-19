# frozen_string_literal: true

require_relative "../server/transports/stdio_transport"

warn <<~MESSAGE, uplevel: 3
  Use `require "mcp/server/transports/stdio_transport"` instead of `require "mcp/transports/stdio"`.
  Also use `MCP::Server::Transports::StdioTransport` instead of `MCP::Transports::StdioTransport`.
  This API is deprecated and will be removed in a future release.
MESSAGE

module MCP
  module Transports
    StdioTransport = Server::Transports::StdioTransport
  end
end
