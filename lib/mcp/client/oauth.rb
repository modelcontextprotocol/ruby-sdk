# frozen_string_literal: true

require_relative "oauth/discovery"
require_relative "oauth/flow"
require_relative "oauth/in_memory_storage"
require_relative "oauth/pkce"
require_relative "oauth/provider"

module MCP
  class Client
    # OAuth client support for the MCP Authorization spec (PRM discovery,
    # Authorization Server metadata discovery, Dynamic Client Registration,
    # OAuth 2.1 Authorization Code + PKCE).
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
    module OAuth
    end
  end
end
