# frozen_string_literal: true

module MCP
  class Client
    # Client-side helpers for the `elicitation/create` server-to-client request.
    # https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation
    module Elicitation
      # Fills fields omitted from `content` with the `default` values declared in
      # the elicitation request's `requestedSchema` properties, per SEP-1034.
      # Provided values are never overwritten, and properties without a `default`
      # are left out so the server can apply its own handling.
      # Mirrors the TypeScript SDK's `applyElicitationDefaults`; the Python SDK
      # applies defaults in the elicitation callback the same way this helper
      # is intended to be used.
      #
      # @param requested_schema [Hash] The `requestedSchema` from the `elicitation/create`
      #   request params (string or symbol keys).
      # @param content [Hash] Values already collected from the user.
      # @return [Hash] `content` (string keys) with defaults filled in.
      #
      # @example Accept an elicitation request with all defaults
      #   transport.on_server_request("elicitation/create") do |params|
      #     {
      #       action: "accept",
      #       content: MCP::Client::Elicitation.apply_defaults(params["requestedSchema"]),
      #     }
      #   end
      class << self
        def apply_defaults(requested_schema, content = {})
          filled = content.to_h.transform_keys(&:to_s)
          properties = requested_schema["properties"] || requested_schema[:properties]
          return filled unless properties.is_a?(Hash)

          properties.each do |name, property_schema|
            name = name.to_s
            next if filled.key?(name)
            next unless property_schema.is_a?(Hash)

            if property_schema.key?("default")
              filled[name] = property_schema["default"]
            elsif property_schema.key?(:default)
              filled[name] = property_schema[:default]
            end
          end

          filled
        end
      end
    end
  end
end
