# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # The decision an `authorization_request_validator` is asked to approve: which authorization server this client is about to send the user to,
      # and with which scopes.
      #
      # Handed over as one object rather than as keyword arguments so that later revisions of the MCP authorization specification can add to it
      # without changing the shape every implementer wrote.
      #
      # Only the named readers are the contract. The positional access `Struct` also provides (`request[0]`, `to_a`, `each`) is not,
      # so the representation can change later.
      AuthorizationRequest = Struct.new(
        # `issuer` of the authorization server selected from the MCP server's Protected Resource Metadata.
        :authorization_server,
        # The scopes about to be requested, as an Array. Chosen by the MCP server, through the `WWW-Authenticate` challenge or `scopes_supported`.
        :scopes,
        # The MCP server URL this client was configured with.
        :server_url,
        # The RFC 8707 `resource` the token is being requested for.
        :resource,
        keyword_init: true,
      )
    end
  end
end
