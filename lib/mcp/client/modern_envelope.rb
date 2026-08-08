# frozen_string_literal: true

require_relative "../request_envelope"

module MCP
  class Client
    # Stamps the SEP-2575 per-request `_meta` envelope onto outgoing modern requests.
    # The reserved key names are shared with the server-side `MCP::RequestEnvelope`.
    # Reserved keys always win over caller-supplied `_meta` entries because they are
    # wire vocabulary the SDK is responsible for; every other entry is preserved.
    module ModernEnvelope
      extend self

      # Returns a copy of `request` with `params._meta` carrying the modern triple.
      # Neither `request` nor its nested hashes are mutated.
      def stamp(request, protocol_version:, client_info:, capabilities:)
        params_key = request.key?("params") ? "params" : :params
        params = request[params_key] || {}
        meta_key = params.key?("_meta") ? "_meta" : :_meta
        meta = params[meta_key] || {}

        stamped_meta = meta.merge(
          RequestEnvelope::PROTOCOL_VERSION_META_KEY.to_sym => protocol_version,
          RequestEnvelope::CLIENT_INFO_META_KEY.to_sym => client_info,
          RequestEnvelope::CLIENT_CAPABILITIES_META_KEY.to_sym => capabilities,
        )

        request.merge(params_key => params.merge(meta_key => stamped_meta))
      end
    end
  end
end
