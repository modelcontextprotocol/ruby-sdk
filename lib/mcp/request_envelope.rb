# frozen_string_literal: true

module MCP
  # The per-request `_meta` envelope of the stateless "modern" lifecycle (MCP 2026-07-28, SEP-2575).
  # The modern lifecycle has no `initialize` handshake: every request identifies its protocol version
  # and client capabilities through reserved `_meta` keys (plus an optional client identity),
  # and the server validates each request independently. Servers MUST NOT infer capabilities from
  # prior requests, which is why the envelope is a per-request value object rather than session state.
  #
  # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575
  class RequestEnvelope
    PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
    CLIENT_INFO_META_KEY = "io.modelcontextprotocol/clientInfo"
    CLIENT_CAPABILITIES_META_KEY = "io.modelcontextprotocol/clientCapabilities"

    # Optional per-request log level, replacing the `logging/setLevel` RPC in the modern lifecycle.
    # Deprecated as of 2026-07-28 (SEP-2577) but still part of the wire format.
    LOG_LEVEL_META_KEY = "io.modelcontextprotocol/logLevel"
    # Notification-side reserved key (SEP-2575): correlates a notification delivered on
    # a `subscriptions/listen` stream (and the stream's closing result) with the JSON-RPC id of
    # the `subscriptions/listen` request that opened it. Not part of the request envelope triple.
    SUBSCRIPTION_ID_META_KEY = "io.modelcontextprotocol/subscriptionId"

    # Result-side counterpart of the request envelope: the server's identity rides in
    # the result's `_meta` as an optional stamp, not as a top-level field, since the SEP was
    # finalized (spec PR modelcontextprotocol/modelcontextprotocol#3002). A server MAY omit it.
    SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"

    # `clientInfo` is deliberately absent: it became optional after the SEP was finalized
    # (spec PR modelcontextprotocol/modelcontextprotocol#3002), so servers MUST accept
    # envelopes without it. The TypeScript and Python SDKs validate the same required pair.
    REQUIRED_META_KEYS = [
      PROTOCOL_VERSION_META_KEY,
      CLIENT_CAPABILITIES_META_KEY,
    ].freeze

    class << self
      # A request claims the modern lifecycle when its `_meta` carries `io.modelcontextprotocol/protocolVersion`,
      # matching the TypeScript SDK's envelope claim and the Python SDK's `_has_modern_envelope`.
      # Classification is deliberately looser than validation: a claimed-but-malformed envelope is
      # rejected by {parse!} with `-32602` instead of silently flowing through the legacy path,
      # while `_meta` without the claim key (`progressToken`, trace context) stays legacy.
      def modern?(params)
        meta = extract_meta(params)
        return false unless meta.is_a?(Hash)

        !read(meta, PROTOCOL_VERSION_META_KEY).nil?
      end

      # Parses and validates the envelope: `protocolVersion` and `clientCapabilities` are required,
      # `clientInfo` is optional. A missing or mistyped field is Invalid params (`-32602`) naming
      # the offending keys, the code and shape the spec mandates and the reference SDKs emit.
      # `request` is only used to enrich the raised error; callers dispatching notifications can omit it.
      def parse!(params, request: nil)
        meta = extract_meta(params)
        meta = {} unless meta.is_a?(Hash)

        protocol_version = read(meta, PROTOCOL_VERSION_META_KEY)
        client_info = read(meta, CLIENT_INFO_META_KEY)
        client_capabilities = read(meta, CLIENT_CAPABILITIES_META_KEY)

        invalid_keys = []
        invalid_keys << PROTOCOL_VERSION_META_KEY unless protocol_version.is_a?(String)
        invalid_keys << CLIENT_CAPABILITIES_META_KEY unless client_capabilities.is_a?(Hash)
        invalid_keys << CLIENT_INFO_META_KEY unless client_info.nil? || client_info.is_a?(Hash)

        unless invalid_keys.empty?
          raise Server::RequestHandlerError.new(
            "Invalid params: missing or invalid `#{invalid_keys.join("`, `")}` in `_meta`",
            request,
            error_type: :invalid_params,
            error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS,
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

    # `client_info` is `nil` when the client chose not to identify itself, which is legal:
    # it is self-reported data and MUST NOT drive behavior or security decisions anyway.
    attr_reader :protocol_version, :client_info, :client_capabilities, :log_level

    def initialize(protocol_version:, client_capabilities:, client_info: nil, log_level: nil)
      @protocol_version = protocol_version
      @client_info = client_info
      @client_capabilities = client_capabilities
      @log_level = log_level
      freeze
    end
  end
end
