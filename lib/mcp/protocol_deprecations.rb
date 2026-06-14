# frozen_string_literal: true

require_relative "configuration"

module MCP
  module ProtocolDeprecations
    extend self

    ROOTS_MESSAGE =
      "MCP Roots (`roots/list` and `notifications/roots/list_changed`) is deprecated as of protocol version " \
        "2026-07-28 (SEP-2577). Use tool parameters, resource URIs, server configuration, or environment " \
        "variables instead."
    SAMPLING_MESSAGE =
      "MCP Sampling (`sampling/createMessage`) is deprecated as of protocol version 2026-07-28 (SEP-2577). " \
        "Use direct LLM provider APIs instead."
    LOGGING_MESSAGE =
      "MCP Logging (`logging/setLevel` and `notifications/message`) is deprecated as of protocol version " \
        "2026-07-28 (SEP-2577). Use stderr or OpenTelemetry instead."

    MESSAGES = {
      roots: ROOTS_MESSAGE,
      sampling: SAMPLING_MESSAGE,
      logging: LOGGING_MESSAGE,
    }.freeze

    def deprecated_roots_sampling_logging?(protocol_version)
      protocol_version == Configuration::ROOTS_SAMPLING_LOGGING_DEPRECATED_PROTOCOL_VERSION
    end

    def warn_for(feature, protocol_version:, uplevel: 1)
      return unless deprecated_roots_sampling_logging?(protocol_version)

      Kernel.warn(MESSAGES.fetch(feature), uplevel: uplevel)
    end

    def warn_for_client_capabilities(capabilities, protocol_version:, uplevel: 1)
      return unless deprecated_roots_sampling_logging?(protocol_version)
      return unless capabilities

      warn_for(:roots, protocol_version: protocol_version, uplevel: uplevel) if capability?(capabilities, :roots)
      warn_for(:sampling, protocol_version: protocol_version, uplevel: uplevel) if capability?(capabilities, :sampling)
    end

    private

    def capability?(capabilities, key)
      capabilities.key?(key) || capabilities.key?(key.to_s)
    end
  end
end
