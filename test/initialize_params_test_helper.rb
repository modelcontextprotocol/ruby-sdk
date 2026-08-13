# frozen_string_literal: true

module InitializeParamsTestHelper
  # `initialize` params satisfying the fields required by the MCP schema
  # (protocolVersion, capabilities, and clientInfo). Offers the latest handshake version
  # so helper-built sessions run the version they request; the counter-offer for
  # modern versions has its own dedicated tests.
  def initialize_params(**overrides)
    {
      protocolVersion: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "test-client", version: "1.0.0" },
    }.merge(overrides)
  end
end
