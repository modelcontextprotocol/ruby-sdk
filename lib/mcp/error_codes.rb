# frozen_string_literal: true

module MCP
  # MCP-specific JSON-RPC error codes, complementing the generic codes in `JsonRpcHandler::ErrorCode`.
  #
  # All three constants below are introduced by the stateless lifecycle of the MCP 2026-07-28 draft (SEP-2575):
  #
  # - `HEADER_MISMATCH` rejects an HTTP request whose headers do not match the corresponding body values,
  #   or whose required headers are missing or malformed (no `error.data`). It is reserved for
  #   the Streamable HTTP transport, since headers do not exist on stdio.
  # - `MISSING_REQUIRED_CLIENT_CAPABILITY` rejects a request that requires a client capability
  #   the request did not declare (`error.data: { requiredCapabilities: {...} }`).
  #   Raised via `Server::MissingRequiredClientCapabilityError`.
  # - `UNSUPPORTED_PROTOCOL_VERSION` rejects a request whose `_meta`-carried protocol version the server
  #   does not support (`error.data: { supported: [...], requested: "..." }`). Raised via
  #   `Server::UnsupportedProtocolVersionError`.
  #
  # The values come from the spec's MCP-specific error code block, which is allocated sequentially from `-32020`
  # toward `-32099`.
  #
  # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
  module ErrorCodes
    HEADER_MISMATCH = -32020
    MISSING_REQUIRED_CLIENT_CAPABILITY = -32021
    UNSUPPORTED_PROTOCOL_VERSION = -32022
  end
end
