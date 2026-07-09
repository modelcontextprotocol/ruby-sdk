# frozen_string_literal: true

module MCP
  # MCP-specific JSON-RPC error codes, complementing the generic codes in `JsonRpcHandler::ErrorCode`.
  #
  # Both constants below are introduced by the stateless lifecycle of the MCP 2026-07-28 draft (SEP-2575):
  # `UNSUPPORTED_PROTOCOL_VERSION` rejects a request whose `_meta`-carried protocol version the server does not
  # support (`error.data: { supported: [...], requested: "..." }`), and `MISSING_REQUIRED_CLIENT_CAPABILITY`
  # rejects a request that requires a client capability the request did not declare
  # (`error.data: { requiredCapabilities: {...} }`). The SDK exports the vocabulary; it does not raise
  # these codes itself yet.
  #
  # The values come from the spec's MCP-specific error code block, which is allocated sequentially from
  # `-32020` toward `-32099`. `-32020` (`HEADER_MISMATCH`, SEP-2243) precedes the two codes defined here.
  #
  # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
  module ErrorCodes
    MISSING_REQUIRED_CLIENT_CAPABILITY = -32021
    UNSUPPORTED_PROTOCOL_VERSION = -32022
  end
end
