# frozen_string_literal: true

module MCP
  # The per-request `_meta` envelope of the stateless "modern" lifecycle (MCP 2026-07-28, SEP-2575).
  # The modern lifecycle has no `initialize` handshake: every request identifies its protocol version,
  # client, and client capabilities through reserved `_meta` keys, and the server validates
  # each request independently. Servers MUST NOT infer capabilities from prior requests,
  # which is why the envelope is a per-request value object rather than session state.
  #
  # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
  class RequestEnvelope
    PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
    CLIENT_INFO_META_KEY = "io.modelcontextprotocol/clientInfo"
    CLIENT_CAPABILITIES_META_KEY = "io.modelcontextprotocol/clientCapabilities"

    # Optional per-request log level, replacing the `logging/setLevel` RPC in the modern lifecycle.
    # Deprecated as of 2026-07-28 (SEP-2577) but still part of the wire format.
    LOG_LEVEL_META_KEY = "io.modelcontextprotocol/logLevel"

    # Result-side counterpart of the request envelope: the server's identity rides in
    # the result's `_meta` as an optional stamp, not as a top-level field, since the SEP was
    # finalized (spec PR modelcontextprotocol/modelcontextprotocol#3002). A server MAY omit it.
    SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"

    REQUIRED_META_KEYS = [
      PROTOCOL_VERSION_META_KEY,
      CLIENT_INFO_META_KEY,
      CLIENT_CAPABILITIES_META_KEY,
    ].freeze

    class << self
      # A request is classified as modern only when the full REQUIRED triple is present,
      # matching the TypeScript SDK's `RequestMetaEnvelopeSchema` and the Python SDK's `_has_modern_envelope`.
      # A partial triple is treated as legacy so existing `_meta` usage (`progressToken`, trace context) keeps
      # flowing through the legacy path.
      def modern?(params)
        meta = extract_meta(params)
        return false unless meta.is_a?(Hash)

        REQUIRED_META_KEYS.all? { |key| !read(meta, key).nil? }
      end

      # Parses and validates the envelope. `request` is only used to enrich the raised error;
      # callers dispatching notifications can omit it.
      def parse!(params, request: nil)
        meta = extract_meta(params)
        meta = {} unless meta.is_a?(Hash)

        protocol_version = read(meta, PROTOCOL_VERSION_META_KEY)
        client_info = read(meta, CLIENT_INFO_META_KEY)
        client_capabilities = read(meta, CLIENT_CAPABILITIES_META_KEY)

        unless protocol_version.is_a?(String) && client_info.is_a?(Hash) && client_capabilities.is_a?(Hash)
          raise Server::RequestHandlerError.new(
            "Invalid Request: modern requests require `#{REQUIRED_META_KEYS.join("`, `")}` in `_meta`",
            request,
            error_type: :invalid_request,
          )
        end

        unless Configuration.modern_protocol_version?(protocol_version)
          raise Server::UnsupportedProtocolVersionError.new(protocol_version, request)
        end

        new(
          protocol_version: protocol_version,
          client_info: client_info,
          client_capabilities: client_capabilities,
          log_level: read(meta, LOG_LEVEL_META_KEY),
        )
      end

      private

      # `Server#handle` accepts hashes parsed with either symbol or string keys, so read both forms
      # (the same tolerance as `Server#handle_cancelled_notification`).
      def extract_meta(params)
        return unless params.is_a?(Hash)

        meta = params[:_meta]
        meta.nil? ? params["_meta"] : meta
      end

      def read(meta, key)
        value = meta[key.to_sym]
        value.nil? ? meta[key] : value
      end
    end

    attr_reader :protocol_version, :client_info, :client_capabilities, :log_level

    def initialize(protocol_version:, client_info:, client_capabilities:, log_level: nil)
      @protocol_version = protocol_version
      @client_info = client_info
      @client_capabilities = client_capabilities
      @log_level = log_level
      freeze
    end
  end
end
