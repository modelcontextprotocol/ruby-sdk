# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "securerandom"
require "uri"

module MCP
  class Client
    module OAuth
      # Internal orchestrator for the MCP OAuth 2.1 + PKCE + DCR authorization flow.
      # Driven by `MCP::Client::HTTP` on a 401 response. The user-facing surface is
      # `Provider`; this class consumes a Provider plus signal data extracted from
      # the failing response (resource_metadata URL, scope challenge).
      class Flow
        class AuthorizationError < StandardError; end

        # Raised specifically when the token endpoint rejects a grant with
        # `error: "invalid_grant"` (RFC 6749 §5.2). Callers use this to
        # distinguish "the stored refresh token is dead, discard it" from
        # transient failures (network, 5xx, other RFC 6749 error codes) that
        # should leave the refresh token intact.
        class InvalidGrantError < AuthorizationError; end

        def initialize(provider:, http_client_factory: nil)
          @provider = provider
          @http_client_factory = http_client_factory || -> { default_http_client }
        end

        # Runs the full discovery, registration, authorization, and token exchange flow.
        # On success, persists tokens via the provider and returns `:authorized`.
        def run!(server_url:, resource_metadata_url: nil, scope: nil)
          # The `resource_metadata` URL ships in `WWW-Authenticate` and is the very
          # first thing we contact in the OAuth flow, so it has to clear the same
          # Communication Security bar as the OAuth endpoints downstream.
          if resource_metadata_url
            ensure_secure_url!(resource_metadata_url, label: "WWW-Authenticate resource_metadata URL")
          end

          prm = fetch_protected_resource_metadata(
            server_url: server_url,
            resource_metadata_url: resource_metadata_url,
          )
          authorization_server = first_authorization_server(prm)
          ensure_secure_url!(authorization_server, label: "PRM `authorization_servers` entry")

          # Per RFC 8707 + MCP authorization, the canonical MCP server URI is sent on
          # both the authorization and token requests. When PRM advertises a `resource`,
          # it MUST identify the same MCP server we are talking to; otherwise we are
          # being redirected to credentials minted for a different audience.
          resource = canonical_resource(server_url: server_url, prm_resource: prm["resource"])

          as_metadata = fetch_authorization_server_metadata(issuer_url: authorization_server)
          ensure_issuer_matches!(expected: authorization_server, returned: as_metadata["issuer"])
          ensure_secure_endpoints!(as_metadata)
          ensure_pkce_supported!(as_metadata)

          client_info = ensure_client_registered(as_metadata: as_metadata)

          effective_scope = resolve_scope(scope: scope, prm: prm)
          pkce = PKCE.generate
          state = SecureRandom.urlsafe_base64(32)

          authorization_url = build_authorization_url(
            as_metadata: as_metadata,
            client_id: client_info_required_value(client_info, "client_id"),
            scope: effective_scope,
            state: state,
            code_challenge: pkce[:code_challenge],
            resource: resource,
          )

          @provider.redirect_handler.call(authorization_url)
          code, returned_state = Array(@provider.callback_handler.call)
          raise AuthorizationError, "Authorization callback did not return an authorization code." unless code

          unless states_match?(returned_state, state)
            raise AuthorizationError, "OAuth state mismatch (CSRF protection)."
          end

          tokens = exchange_authorization_code(
            as_metadata: as_metadata,
            client_info: client_info,
            code: code,
            code_verifier: pkce[:code_verifier],
            resource: resource,
          )

          @provider.save_tokens(tokens)
          :authorized
        end

        # Exchanges the saved `refresh_token` for a fresh access token (RFC 6749
        # Section 6). Re-discovers PRM and AS metadata so we always pick up a moved
        # token endpoint, and re-runs the audience / issuer / security checks
        # before talking to it.
        #
        # Returns `:refreshed` on success. Raises `AuthorizationError` when
        # the provider has no refresh token, no client information, or when
        # the token endpoint refuses the refresh request.
        # https://www.rfc-editor.org/rfc/rfc6749#section-6
        def refresh!(server_url:, resource_metadata_url: nil)
          refresh_token = read_token("refresh_token")
          raise AuthorizationError, "Cannot refresh: no refresh_token in provider storage." unless refresh_token

          client_info = @provider.client_information
          unless client_info.is_a?(Hash) && client_info_required_value(client_info, "client_id")
            raise AuthorizationError, "Cannot refresh: no client_information in provider storage."
          end

          if resource_metadata_url
            ensure_secure_url!(resource_metadata_url, label: "WWW-Authenticate resource_metadata URL")
          end

          prm = fetch_protected_resource_metadata(
            server_url: server_url,
            resource_metadata_url: resource_metadata_url,
          )
          authorization_server = first_authorization_server(prm)
          ensure_secure_url!(authorization_server, label: "PRM `authorization_servers` entry")

          resource = canonical_resource(server_url: server_url, prm_resource: prm["resource"])

          as_metadata = fetch_authorization_server_metadata(issuer_url: authorization_server)
          ensure_issuer_matches!(expected: authorization_server, returned: as_metadata["issuer"])
          ensure_secure_endpoints!(as_metadata)

          new_tokens = exchange_refresh_token(
            as_metadata: as_metadata,
            client_info: client_info,
            refresh_token: refresh_token,
            resource: resource,
          )

          @provider.save_tokens(preserve_refresh_token(new_tokens, refresh_token))
          :refreshed
        end

        private

        def read_token(key)
          tokens = @provider.tokens
          return unless tokens.is_a?(Hash)

          value = tokens[key] || tokens[key.to_sym]
          value.to_s.empty? ? nil : value
        end

        # Per RFC 6749 Section 6, the refresh response MAY omit `refresh_token`, in
        # which case the previous one stays valid. Preserve it explicitly so
        # downstream refresh attempts still work.
        def preserve_refresh_token(new_tokens, previous_refresh_token)
          return new_tokens if new_tokens["refresh_token"] || new_tokens[:refresh_token]

          new_tokens.merge("refresh_token" => previous_refresh_token)
        end

        def fetch_protected_resource_metadata(server_url:, resource_metadata_url:)
          urls = Discovery.protected_resource_metadata_urls(
            server_url: server_url,
            resource_metadata_url: resource_metadata_url,
          )
          fetch_metadata_json(urls, label: "protected resource metadata")
        end

        def fetch_authorization_server_metadata(issuer_url:)
          urls = Discovery.authorization_server_metadata_urls(issuer_url)
          fetch_metadata_json(urls, label: "authorization server metadata")
        end

        # Reads `authorization_servers` from a PRM document and returns
        # the first entry, raising `AuthorizationError` for any of the malformed
        # shapes a non-compliant server could emit (missing field, non-Array
        # value, empty Array, non-String first entry). Centralizing this lets
        # both the full flow and the refresh flow share the same defensive
        # parse instead of each one duplicating a Hash-and-Array check.
        def first_authorization_server(prm)
          authorization_servers = prm["authorization_servers"]
          unless authorization_servers.is_a?(Array)
            raise AuthorizationError,
              "Protected resource metadata `authorization_servers` is not an array " \
                "(got #{authorization_servers.class})."
          end

          if authorization_servers.empty?
            raise AuthorizationError, "Protected resource metadata has no authorization_servers."
          end

          first = authorization_servers.first
          unless first.is_a?(String) && !first.empty?
            raise AuthorizationError,
              "Protected resource metadata `authorization_servers[0]` is not a non-empty string."
          end

          first
        end

        # Walks candidate metadata URLs and returns the parsed JSON body of
        # the first 2xx response. Raises `AuthorizationError` for transport
        # failures (`Faraday::Error`) and malformed bodies (`JSON::ParserError`)
        # so callers do not have to handle raw Faraday/JSON exceptions.
        def fetch_metadata_json(urls, label:)
          last_error = nil
          urls.each do |url|
            response = begin
              http_get(url)
            rescue Faraday::Error => e
              last_error = "GET #{url} raised #{e.class}: #{e.message}"
              next
            end

            if response.status >= 200 && response.status < 300
              parsed = begin
                JSON.parse(response_body_string(response))
              rescue JSON::ParserError => e
                raise AuthorizationError, "Failed to parse #{label} from #{url}: #{e.message}."
              end

              # Even valid JSON can be the wrong shape (a top-level array,
              # a bare `null`, a string, ...). The discovery callers index by
              # name (`prm["authorization_servers"]`, etc.), so anything that
              # is not a Hash would raise `TypeError` / `NoMethodError`
              # downstream. Surface that as `AuthorizationError` instead so
              # callers see a single, documented error type.
              unless parsed.is_a?(Hash)
                raise AuthorizationError,
                  "#{label} from #{url} is not a JSON object (got #{parsed.class})."
              end

              return parsed
            end

            last_error = "GET #{url} returned #{response.status}"
          end
          raise AuthorizationError, "Failed to fetch #{label}: #{last_error}."
        end

        def ensure_pkce_supported!(as_metadata)
          methods = as_metadata["code_challenge_methods_supported"]
          return if methods.is_a?(Array) && methods.include?("S256")

          raise AuthorizationError,
            "Authorization server does not advertise S256 PKCE support; refusing to proceed."
        end

        # Per the MCP authorization spec's Communication Security requirement,
        # OAuth endpoints MUST use HTTPS unless the host is a loopback address.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#communication-security
        def ensure_secure_url!(url, label:)
          return if Discovery.secure_url?(url)

          raise AuthorizationError,
            "#{label} #{url.inspect} is not over HTTPS; refusing to use it (MCP authorization Communication Security)."
        end

        def ensure_secure_endpoints!(as_metadata)
          ["authorization_endpoint", "token_endpoint", "registration_endpoint"].each do |key|
            endpoint = as_metadata[key]
            ensure_secure_url!(endpoint, label: "Authorization server #{key}") if endpoint
          end
        end

        # Per RFC 8414 Section 3.3, the AS metadata document's `issuer` value MUST be
        # identical (literal byte-for-byte equality, no normalization) to
        # the issuer URL the client used to discover that document. This guards
        # against a CDN/relay returning the metadata of a *different*
        # authorization server than the one PRM advertised, and against
        # ambiguities like trailing `/`, fragments, or case differences that
        # could mask a confused-deputy attempt.
        # https://www.rfc-editor.org/rfc/rfc8414#section-3.3
        def ensure_issuer_matches!(expected:, returned:)
          unless returned
            raise AuthorizationError, "Authorization server metadata is missing the `issuer` field."
          end

          return if expected.to_s == returned.to_s

          raise AuthorizationError,
            "Authorization server metadata `issuer` does not match the discovery URL " \
              "(expected #{expected.inspect}, got #{returned.inspect})."
        end

        def ensure_client_registered(as_metadata:)
          existing = @provider.client_information
          return existing if existing.is_a?(Hash) && client_info_required_value(existing, "client_id")

          registration_endpoint = as_metadata["registration_endpoint"]
          unless registration_endpoint
            raise AuthorizationError,
              "Authorization server has no registration_endpoint and no pre-registered client information was provided."
          end

          response = begin
            http_post_json(registration_endpoint, @provider.client_metadata)
          rescue Faraday::Error => e
            raise AuthorizationError,
              "Dynamic client registration failed: #{e.class}: #{e.message}."
          end

          if response.status < 200 || response.status >= 300
            raise AuthorizationError, "Dynamic client registration failed with status #{response.status}."
          end

          info = begin
            JSON.parse(response_body_string(response))
          rescue JSON::ParserError => e
            raise AuthorizationError,
              "Failed to parse dynamic client registration response: #{e.message}."
          end

          unless info.is_a?(Hash) && client_info_required_value(info, "client_id")
            raise AuthorizationError,
              "Dynamic client registration response is missing `client_id`."
          end

          @provider.save_client_information(info)
          info
        end

        # Reads `key` from a `client_information` hash that may use either string or
        # symbol keys, so users can persist the result of `JSON.parse` *or* a hand-built
        # `{ client_id:, client_secret: }` and have both work.
        def client_info_value(info, key)
          info[key] || info[key.to_sym]
        end

        # Same as `client_info_value` but treats blank strings (`""` or only
        # whitespace) as absent. Used for fields where empty values are never
        # meaningful (`client_id`, `client_secret`, `token_endpoint_auth_method`)
        # and would otherwise let a misbehaving AS or hand-built
        # `client_information` short-circuit the "is the client registered?"
        # check, or send a literal `client_secret: "   "` to the token endpoint.
        def client_info_required_value(info, key)
          value = client_info_value(info, key)
          return if value.nil?
          return if value.is_a?(String) && value.strip.empty?

          value
        end

        # Returns the canonical RFC 8707 `resource` URI to send on authorization and
        # token requests. When PRM advertises `resource`, that value is
        # the authorization server's idea of the resource identifier and is preferred.
        # When PRM omits it, the canonicalized MCP server URL is used.
        #
        # Either way, we validate that PRM's `resource` covers the MCP server URL
        # the client is actually talking to (same origin, with PRM's path as a prefix of
        # the server URL's path) to prevent a malicious or misconfigured PRM from
        # redirecting credentials to a different audience.
        def canonical_resource(server_url:, prm_resource:)
          server_canonical = safe_canonicalize_url(server_url, label: "MCP server URL")
          return server_canonical unless prm_resource

          prm_canonical = safe_canonicalize_url(prm_resource, label: "PRM `resource`")
          unless Discovery.resource_covers?(prm: prm_canonical, server: server_canonical)
            raise AuthorizationError,
              "Protected resource metadata `resource` does not match the MCP server URL " \
                "(server=#{server_canonical}, prm=#{prm_canonical})."
          end

          prm_canonical
        end

        # Wraps `Discovery.canonicalize_url` so that any URI parsing failure
        # caused by malformed input from the server (`PRM.resource`, AS metadata
        # endpoints, ...) surfaces as `AuthorizationError` instead of leaking
        # a raw `URI::InvalidURIError` / `ArgumentError`.
        def safe_canonicalize_url(url, label:)
          Discovery.canonicalize_url(url)
        rescue URI::InvalidURIError, ArgumentError => e
          raise AuthorizationError, "#{label} #{url.inspect} is not a valid URI: #{e.message}."
        end

        # Constant-time comparison for the OAuth `state` parameter to prevent timing-based discovery
        # of the expected value.
        # `OpenSSL.fixed_length_secure_compare` would be ideal, but it is not available on Ruby 2.7
        # (the project's minimum supported version).
        # The hand-rolled XOR-sum walks every byte of the equal-length operands, so the running time
        # does not leak the position of the first mismatching byte.
        def states_match?(returned, expected)
          returned = returned.to_s
          return false unless returned.bytesize == expected.bytesize

          result = 0
          returned.bytes.zip(expected.bytes) { |a, b| result |= a ^ b }
          result.zero?
        end

        # Per MCP 2025-11-25 Authorization and the TS/Python SDKs, scope resolution
        # prefers the `WWW-Authenticate` challenge first, then `scopes_supported`
        # from the Protected Resource Metadata, and falls back to a provider-supplied
        # scope only if both are absent. The provider-supplied scope must not pre-empt
        # a server-advertised one.
        def resolve_scope(scope:, prm:)
          return scope if scope && !scope.empty?

          supported = prm["scopes_supported"]
          return supported.join(" ") if supported.is_a?(Array) && !supported.empty?

          return @provider.scope if @provider.scope && !@provider.scope.empty?

          nil
        end

        def build_authorization_url(as_metadata:, client_id:, scope:, state:, code_challenge:, resource:)
          authorization_endpoint = as_metadata["authorization_endpoint"]
          unless authorization_endpoint
            raise AuthorizationError,
              "Authorization server metadata is missing `authorization_endpoint`."
          end

          uri = begin
            URI.parse(authorization_endpoint)
          rescue URI::InvalidURIError => e
            raise AuthorizationError,
              "Authorization server metadata `authorization_endpoint` is not a valid URI: #{e.message}."
          end

          params = URI.decode_www_form(uri.query.to_s)
          params << ["response_type", "code"]
          params << ["client_id", client_id]
          params << ["redirect_uri", @provider.redirect_uri]
          params << ["code_challenge", code_challenge]
          params << ["code_challenge_method", "S256"]
          params << ["state", state]
          params << ["scope", scope] if scope
          params << ["resource", resource] if resource
          uri.query = URI.encode_www_form(params)
          uri
        end

        def exchange_authorization_code(as_metadata:, client_info:, code:, code_verifier:, resource:)
          form = {
            "grant_type" => "authorization_code",
            "code" => code,
            "redirect_uri" => @provider.redirect_uri,
            "code_verifier" => code_verifier,
          }
          form["resource"] = resource if resource

          post_to_token_endpoint(as_metadata: as_metadata, client_info: client_info, form: form)
        end

        def exchange_refresh_token(as_metadata:, client_info:, refresh_token:, resource:)
          form = {
            "grant_type" => "refresh_token",
            "refresh_token" => refresh_token,
          }
          form["resource"] = resource if resource

          post_to_token_endpoint(as_metadata: as_metadata, client_info: client_info, form: form)
        end

        # Submits a form-encoded request to the token endpoint, applying
        # the client authentication method advertised in `client_information` and
        # adding `client_id` (and `client_secret` when not using HTTP Basic).
        def post_to_token_endpoint(as_metadata:, client_info:, form:)
          client_id = client_info_required_value(client_info, "client_id")
          unless client_id
            raise AuthorizationError,
              "Cannot post to token endpoint: client_information is missing `client_id`."
          end

          client_secret = client_info_required_value(client_info, "client_secret")
          token_endpoint_auth_method = client_info_value(client_info, "token_endpoint_auth_method")

          form = form.merge("client_id" => client_id)
          headers = {}
          if client_secret
            case token_endpoint_auth_method
            when "client_secret_post"
              form["client_secret"] = client_secret
            when "none"
              # Public client; no credential.
            else
              # RFC 6749 §2.3.1 recommends Basic for confidential clients and
              # both Python and TypeScript SDKs default here when
              # the authentication method is not explicitly stored.
              headers["Authorization"] = "Basic " + basic_auth_credentials(client_id, client_secret)
            end
          end

          token_endpoint = as_metadata["token_endpoint"]
          unless token_endpoint
            raise AuthorizationError,
              "Authorization server metadata is missing `token_endpoint`."
          end

          response = begin
            http_post_form(token_endpoint, form, headers: headers)
          rescue Faraday::Error => e
            raise AuthorizationError,
              "Token request to #{token_endpoint} failed: #{e.class}: #{e.message}."
          end

          if response.status < 200 || response.status >= 300
            if token_endpoint_error_code(response) == "invalid_grant"
              raise InvalidGrantError, "Token endpoint rejected the grant: invalid_grant."
            end

            raise AuthorizationError, "Token endpoint returned status #{response.status}."
          end

          parsed = begin
            JSON.parse(response_body_string(response))
          rescue JSON::ParserError => e
            raise AuthorizationError, "Failed to parse token endpoint response: #{e.message}."
          end

          # Token responses MUST be a JSON object per RFC 6749 §5.1. Anything
          # else (`null`, `[]`, a bare string) would otherwise be persisted
          # as `provider.tokens` and raise raw `NoMethodError` / `TypeError`
          # the next time `provider.access_token` is read.
          unless parsed.is_a?(Hash)
            raise AuthorizationError,
              "Token endpoint response is not a JSON object (got #{parsed.class})."
          end

          parsed
        end

        # Extracts the `error` code from an RFC 6749 §5.2 error response body
        # when one is parseable. Returns nil on any parse failure or when
        # the body is not JSON.
        def token_endpoint_error_code(response)
          body = response_body_string(response).to_s
          return if body.empty?

          parsed = JSON.parse(body)
          parsed["error"] if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        # Per RFC 6749 Section 2.3.1, the `client_id` and `client_secret` MUST be
        # `application/x-www-form-urlencoded` encoded before they are joined with
        # `:` and base64-encoded for the `Authorization: Basic` header. This is
        # what prevents credentials containing `:` or other special characters
        # from being mis-parsed by the authorization server.
        # https://www.rfc-editor.org/rfc/rfc6749#section-2.3.1
        def basic_auth_credentials(client_id, client_secret)
          encoded_id = URI.encode_www_form_component(client_id)
          encoded_secret = URI.encode_www_form_component(client_secret)
          Base64.strict_encode64("#{encoded_id}:#{encoded_secret}")
        end

        def http_get(url)
          http_client.get(url)
        end

        def http_post_json(url, body)
          http_client.post(url) do |req|
            req.headers["Content-Type"] = "application/json"
            req.headers["Accept"] = "application/json"
            req.body = JSON.generate(body)
          end
        end

        def http_post_form(url, form, headers: {})
          http_client.post(url) do |req|
            req.headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.headers["Accept"] = "application/json"
            headers.each { |key, value| req.headers[key] = value }
            req.body = URI.encode_www_form(form)
          end
        end

        def http_client
          @http_client ||= @http_client_factory.call
        end

        def default_http_client
          require "faraday"
          Faraday.new do |faraday|
            faraday.headers["Accept"] = "application/json"
          end
        end

        def response_body_string(response)
          body = response.body
          body.is_a?(String) ? body : body.to_s
        end
      end
    end
  end
end
