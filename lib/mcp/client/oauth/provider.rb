# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Pluggable OAuth client configuration for the OAuth 2.1 Authorization Code + PKCE flow,
      # handed to `MCP::Client::HTTP` via the `oauth:` keyword.
      # Inspired by the OAuthClientProvider in the TypeScript SDK and the httpx.Auth-based provider
      # in the Python SDK. For the non-interactive machine-to-machine `client_credentials` grant,
      # use `ClientCredentialsProvider` instead.
      #
      # Required keyword arguments:
      # - `client_metadata`  - Hash sent to the authorization server's Dynamic Client
      #   Registration endpoint. Must include at minimum `redirect_uris`,
      #   `grant_types`, `response_types`, and `token_endpoint_auth_method`.
      #   When `application_type` is omitted, the SDK infers `"native"` or `"web"`
      #   from `redirect_uris` per SEP-837 before registering; an explicit value
      #   always wins.
      # - `redirect_uri`     - String: the redirect URI used for the authorization
      #   request. Must be one of `redirect_uris` in `client_metadata`.
      # - `redirect_handler` - Callable invoked with the fully-built authorization
      #   URL (a `URI`). Implementations typically open the user's browser.
      # - `callback_handler` - Callable invoked after `redirect_handler`. Returns
      #   `[code, state]` or `[code, state, iss]`, where `code` is the authorization code,
      #   `state` is the `state` parameter received on the redirect URI, and `iss` is
      #   the RFC 9207 `iss` parameter (or nil when the authorization response carried none).
      #   Returning the 3-element form opts into SEP-2468 issuer validation: a present `iss`
      #   must match the authorization server's issuer, and a nil `iss` is
      #   rejected when the AS advertises `authorization_response_iss_parameter_supported`.
      #   The 2-element form skips the check for backward compatibility.
      #
      # Optional keyword arguments:
      # - `scope`   - String of space-separated scopes to request when the server's
      #   `WWW-Authenticate` does not specify one.
      # - `storage` - Object responding to `tokens`, `save_tokens(tokens)`,
      #   `client_information`, and `save_client_information(info)`. Defaults to
      #   an `InMemoryStorage`. Persisted `client_information` is stamped with
      #   an `"issuer"` member binding it to the authorization server that
      #   issued it (SEP-2352); when the authorization server changes, the SDK discards
      #   the stale registration and tokens and re-registers.
      # - `client_id_metadata_document_url` - URL where the client publishes its Client ID Metadata Document
      #   (`draft-ietf-oauth-client-id-metadata-document-00` and the MCP authorization specification).
      #   When the authorization server advertises `client_id_metadata_document_supported: true`,
      #   the SDK uses this URL as the OAuth `client_id` and skips Dynamic Client Registration.
      #   Spec-required: `https://` scheme, a non-root path, and no fragment, userinfo, or `.`/`..` segments.
      #   The SDK additionally refuses to send query strings (the draft marks them only SHOULD NOT include,
      #   but different encodings of the same query would yield different `client_id` strings for the same document).
      #   The document served at the URL is a separate JSON artifact from the `client_metadata` keyword:
      #   DCR `client_metadata` MUST NOT include `client_id`, while the CIMD document MUST include `client_id` set
      #   to the URL, `client_name`, and `redirect_uris` covering `redirect_uri`.
      class Provider
        include StorageBackedProvider

        # Raised when `Provider#initialize` is called with a `redirect_uri` that
        # is neither HTTPS nor a loopback `http://` URL, per the MCP
        # authorization spec's Communication Security requirement.
        class InsecureRedirectURIError < ArgumentError; end

        # Raised when the `redirect_uri` argument is not listed in
        # `client_metadata[:redirect_uris]` / `["redirect_uris"]`. Registering
        # the URI with the authorization server but then sending a different
        # one with the authorization request would be rejected by the AS at
        # runtime; failing at construction surfaces the bug earlier.
        class UnregisteredRedirectURIError < ArgumentError; end

        # Raised when `client_id_metadata_document_url` is provided but does not meet
        # the structural requirements for a Client ID Metadata Document URL:
        # HTTPS, non-root path, and no fragment, query, userinfo, or `.`/`..` segments.
        # The CIMD URL is sent to the authorization server as the OAuth `client_id`,
        # so the same Communication Security guarantee that protects the redirect URI
        # applies and the value must unambiguously identify the document.
        class InvalidClientIDMetadataDocumentURLError < ArgumentError; end

        attr_reader :client_metadata,
          :redirect_uri,
          :scope,
          :storage,
          :redirect_handler,
          :callback_handler,
          :client_id_metadata_document_url

        def initialize(
          client_metadata:,
          redirect_uri:,
          redirect_handler:,
          callback_handler:,
          scope: nil,
          storage: nil,
          client_id_metadata_document_url: nil
        )
          unless Discovery.secure_url?(redirect_uri)
            raise InsecureRedirectURIError,
              "redirect_uri #{redirect_uri.inspect} must use https or be a loopback http URL " \
                "(localhost, 127.0.0.0/8, or ::1) per the MCP authorization Communication Security requirement."
          end

          registered = Array(client_metadata[:redirect_uris] || client_metadata["redirect_uris"])
          unless registered.include?(redirect_uri)
            raise UnregisteredRedirectURIError,
              "redirect_uri #{redirect_uri.inspect} must be listed in client_metadata[:redirect_uris] " \
                "(got #{registered.inspect}); otherwise the authorization server will reject the authorization request."
          end

          if client_id_metadata_document_url && !Discovery.client_id_metadata_document_url?(client_id_metadata_document_url)
            raise InvalidClientIDMetadataDocumentURLError,
              "client_id_metadata_document_url #{client_id_metadata_document_url.inspect} must be an https URL " \
                "with a non-root path and no fragment, query, userinfo, or `.`/`..` segments, " \
                "per the MCP authorization specification and `draft-ietf-oauth-client-id-metadata-document`."
          end

          @client_metadata = client_metadata
          @redirect_uri = redirect_uri
          @redirect_handler = redirect_handler
          @callback_handler = callback_handler
          @scope = scope
          @storage = storage || InMemoryStorage.new
          @client_id_metadata_document_url = client_id_metadata_document_url
        end

        # Identifies the OAuth flow this provider drives.
        # `Flow` dispatches on this rather than inspecting `client_metadata[:grant_types]`,
        # which is protocol metadata for the authorization server, not an SDK control signal.
        def authorization_flow
          :authorization_code
        end
      end
    end
  end
end
