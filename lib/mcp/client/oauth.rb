# frozen_string_literal: true

require_relative "oauth/discovery"
require_relative "oauth/flow"
require_relative "oauth/in_memory_storage"
require_relative "oauth/pkce"
require_relative "oauth/storage_backed_provider"
require_relative "oauth/jwt_client_assertion"
require_relative "oauth/provider"
require_relative "oauth/client_credentials_provider"
require_relative "oauth/id_jag_token_exchange"
require_relative "oauth/cross_app_access_provider"

module MCP
  class Client
    # OAuth client support for the MCP Authorization spec (PRM discovery,
    # Authorization Server metadata discovery, Dynamic Client Registration,
    # OAuth 2.1 Authorization Code + PKCE, the client_credentials grant,
    # and the SEP-990 Enterprise Managed Authorization jwt-bearer grant).
    # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
    module OAuth
    end
  end
end
