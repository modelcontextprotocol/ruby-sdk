# frozen_string_literal: true

module InitializeParamsTestHelper
  # `initialize` params satisfying the fields required by the MCP schema
  # (protocolVersion, capabilities, and clientInfo).
  def initialize_params(**overrides)
    {
      protocolVersion: MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "test-client", version: "1.0.0" },
    }.merge(overrides)
  end
end
