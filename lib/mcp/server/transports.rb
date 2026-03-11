# frozen_string_literal: true

module MCP
  class Server
    module Transports
      autoload :StdioTransport, "mcp/server/transports/stdio_transport"
      autoload :StreamableHTTPTransport, "mcp/server/transports/streamable_http_transport"
    end
  end
end
