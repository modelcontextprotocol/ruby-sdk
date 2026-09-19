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
        TOKEN_ENDPOINT_ERROR_MAX_LENGTH = 128
        TOKEN_ENDPOINT_ERROR_DESCRIPTION_MAX_LENGTH = 512
        METADATA_DIAGNOSTIC_MAX_LENGTH = 128
        METADATA_URL_MAX_LENGTH = 2048

        # Token request parameters the flow sets itself. Its values win over a provider's `token_request_params`,
        # so a provider naming one of these is refused rather than left believing its value was sent.
        RESERVED_TOKEN_REQUEST_PARAMS = [
          "grant_type",
          "client_id",
          "client_secret",
          "client_assertion",
          "client_assertion_type",
          "scope",
          "resource",
          "code",
          "code_verifier",
          "redirect_uri",
          "refresh_token",
          "assertion",
        ].freeze

        class AuthorizationError < StandardError
          attr_reader :http_status, :error, :error_description

          def initialize(message = nil, http_status: nil, error: nil, error_description: nil)
            super(message)
            @http_status = http_status
            @error = error
            @error_description = error_description
          end
        end

        # Raised specifically when the token endpoint rejects a grant with
        # `error: "invalid_grant"` (RFC 6749 §5.2). Callers use this to
        # distinguish "the stored refresh token is dead, discard it" from
        # transient failures (network, 5xx, other RFC 6749 error codes) that
        # should leave the refresh token intact.
        class InvalidGrantError < AuthorizationError; end

        # Raised when `authorization_request_validator` returns a falsy value. Separate from its parent
        # so that a caller can tell a refusal by its own policy from a network, discovery,
        # or authorization server metadata failure by rescuing a class rather than by matching the message text.
        class AuthorizationRefusedError < AuthorizationError; end

        # Raised by metadata discovery when every candidate URL answered that nothing usable is published there
        # (a `4xx` other than `429`, a redirect that was not followed, or a body that is not a JSON object).
        # The only discovery failure that may select the legacy 2025-03-26 path.
        class MetadataNotPublishedError < AuthorizationError; end

        # Raised by metadata discovery when the answer says nothing about what is published: the request failed to
        # reach the server, or a candidate answered `5xx` or `429`. Falling back on this would move
        # the flow to a different authorization server because of a transient failure, so it is surfaced instead,
        # as the TypeScript SDK does for network errors outside browsers and the Python SDK does for both.
        class MetadataUnreachableError < AuthorizationError; end

        # Raised for a `token_request_params` value the SDK refuses: a reserved key, a Hash comparing keys by identity,
        # or anything but a Hash of Strings. An `ArgumentError` because the value is a configuration mistake,
        # not a failed authorization, and deliberately outside `AuthorizationError`, which `MCP::Client::HTTP` treats on
        # a failed refresh as a reason to run the interactive flow.
        class InvalidTokenRequestParamsError < ArgumentError; end

        # Raised by `RequestedOriginGuard` when middleware added through the provider's `http_client_customizer`
        # would send a request to an origin other than the one the flow validated, or has dropped the record of
        # the URL the flow asked for. An `ArgumentError` because the middleware is a configuration mistake,
        # and deliberately outside `AuthorizationError`, which discovery treats as "nothing published"
        # and `MCP::Client::HTTP` treats on a failed refresh as a reason to run the interactive flow.
        class DestinationMismatchError < ArgumentError; end

        # Faraday middleware registered on the connection `build_http_client` assembles before the customizer
        # is invoked, so with the usual `use` it sits ahead of the customizer's middleware and sees the URL exactly
        # as the flow requested it, which it records on the request environment for `RequestedOriginGuard`.
        # The guard covers what happens to a request after that record; middleware inserted ahead of it with
        # `builder.insert(0, ...)` that rewrites the URL before it or rebuilds the environment is outside the guard.
        # The record lives on the environment, not in `env.request.context`: that slot belongs to the application,
        # which may fill it on the connection or replace it from a middleware of its own. Only the first URL seen
        # on an environment is recorded: a middleware inserted ahead of this one that re-enters the stack after
        # a `3xx` with the same environment, or with its `dup`, which shares the record, cannot replace it with
        # the redirected URL.
        class RequestedURLStamp
          KEY = :mcp_oauth_requested_url

          def initialize(app)
            @app = app
          end

          def call(env)
            env[KEY] ||= env.url.to_s
            @app.call(env)
          end
        end

        # Faraday middleware registered last on that connection, so it sees `env.url` after any customizer-added
        # middleware has rewritten it or followed a redirect. A request that would leave the origin the flow asked
        # for is refused before it reaches the adapter, since every destination check ran against the URL as
        # written; a same-origin change stays with the server those checks admitted. The record survives
        # the `env.dup` that redirect-following middleware performs, and a request that arrives without it is
        # refused as well, so a middleware that rebuilds the environment fails closed rather than open.
        # The origin boundary resembles the one the Python SDK keeps for its own auth requests, which follows
        # a redirect itself only within the origin; this flow follows none.
        class RequestedOriginGuard
          def initialize(app)
            @app = app
          end

          def call(env)
            requested = env[RequestedURLStamp::KEY]
            unless requested
              raise DestinationMismatchError, <<~MESSAGE
                Request to #{Discovery.canonicalize_origin_and_path(env.url.to_s).inspect} carries no record of \
                the URL the flow asked for; middleware that rebuilds the request environment is refused.
              MESSAGE
            end

            unless Discovery.same_origin?(env.url.to_s, requested)
              raise DestinationMismatchError, <<~MESSAGE
                Request to #{Discovery.canonicalize_origin_and_path(requested).inspect} would be sent to \
                #{Discovery.canonicalize_origin_and_path(env.url.to_s).inspect}, on a different origin; \
                middleware that follows redirects or rewrites URLs is refused.
              MESSAGE
            end

            @app.call(env)
          end
        end
        private_constant :RequestedURLStamp, :RequestedOriginGuard

        class << self
          # Returns why `params` cannot ride a token request as `token_request_params`, or `nil` when it can.
          # Shared by the provider constructors and the flow, which both refuse the value with `InvalidTokenRequestParamsError`,
          # so the same problem reads the same wherever it surfaces.
          def token_request_params_problem(params)
            return "must be a Hash (got #{params.class})." unless params.is_a?(Hash)

            # Two equal keys are two entries here, which would be sent twice from a provider method
            # or silently collapse into one when the constructors copy the Hash.
            return "must not compare keys by identity." if params.compare_by_identity?

            params.each do |key, value|
              return "keys must be Strings (got #{key.class})." unless key.is_a?(String)
              return "values must be Strings (got #{value.class} for #{key.inspect})." unless value.is_a?(String)
              return "must not set #{key.inspect}, which the SDK sets itself." if RESERVED_TOKEN_REQUEST_PARAMS.include?(key)
            end

            nil
          end

          # Builds the connection the flow uses for its own requests: the SDK's defaults, `RequestedURLStamp`,
          # then `customizer` (a provider's `http_client_customizer`, called with the `Faraday::Connection`),
          # then `RequestedOriginGuard` last so it sees what the customizer's middleware does to each request
          # after the stamp recorded it. Every request on the connection passes through both, so a caller using
          # it directly is held to the same origin rule.
          #
          # Deliberately built without redirect-following middleware. Every destination check in this class runs
          # against the URL as written, before the request goes out, so a connection that transparently followed
          # a `3xx` would let a server reach a host the checks just refused. The guard turns following at
          # the middleware level into a refusal; following inside an adapter stays invisible, so a customizer must
          # not enable it.
          #
          # `Accept-Encoding` is deliberately left unset. `Net::HTTP::GenericRequest` negotiates it and decodes
          # the response only while the caller has not claimed that header; assigning it turns `decode_content` off,
          # which would silently move `BoundedBody`'s cap onto compressed bytes and let a small body expand past it
          # after the check.
          def build_http_client(customizer = nil)
            require "faraday"

            Faraday.new do |faraday|
              faraday.headers["Accept"] = "application/json"
              faraday.use(RequestedURLStamp)
              customizer&.call(faraday)
              faraday.use(RequestedOriginGuard)
            end
          end
        end

        def initialize(provider:, http_client_factory: nil)
          @provider = provider
          @http_client_factory = http_client_factory || -> { default_http_client }
        end

        # Runs the full discovery, registration, authorization, and token exchange flow.
        # On success, persists tokens via the provider and returns `:authorized`.
        def run!(server_url:, resource_metadata_url: nil, scope: nil)
          # The `resource_metadata` URL ships in `WWW-Authenticate` and is the very
          # first thing we contact in the OAuth flow, so it has to clear the same
          # Communication Security bar as the OAuth endpoints downstream, and it has to
          # point back at the server that issued the challenge.
          if resource_metadata_url
            ensure_secure_url!(resource_metadata_url, label: "WWW-Authenticate resource_metadata URL")
            ensure_same_origin!(
              resource_metadata_url,
              label: "WWW-Authenticate resource_metadata URL",
              server_url: server_url,
            )
          end

          prm, authorization_server = locate_authorization_server(
            server_url: server_url,
            resource_metadata_url: resource_metadata_url,
          )

          # Per RFC 8707 + MCP authorization, the canonical MCP server URI is sent on
          # both the authorization and token requests. When PRM advertises a `resource`,
          # it MUST identify the same MCP server we are talking to; otherwise we are
          # being redirected to credentials minted for a different audience.
          resource = canonical_resource(server_url: server_url, prm_resource: prm&.dig("resource"))

          as_metadata = authorization_server_metadata(
            authorization_server: authorization_server,
            legacy: prm.nil?,
            server_url: server_url,
          )

          case provider_authorization_flow
          when :client_credentials
            return run_client_credentials!(as_metadata: as_metadata, prm: prm, resource: resource, scope: scope, server_url: server_url)
          when :jwt_bearer
            return run_jwt_bearer!(as_metadata: as_metadata, prm: prm, resource: resource, scope: scope, server_url: server_url)
          end

          ensure_pkce_supported!(as_metadata)

          effective_scope = resolve_scope(scope: scope, prm: prm)
          effective_scope = normalize_offline_access_scope(effective_scope, as_metadata: as_metadata)

          # Asked before registering, not after: a refusal must not leave this client registered at an authorization server
          # the embedding application has just rejected.
          authorize_request!(as_metadata: as_metadata, scope: effective_scope, server_url: server_url, resource: resource)

          client_info = ensure_client_registered(as_metadata: as_metadata)

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
          callback_result = Array(@provider.callback_handler.call)
          code, returned_state, returned_iss = callback_result
          raise AuthorizationError, "Authorization callback did not return an authorization code." unless code

          unless states_match?(returned_state, state)
            raise AuthorizationError, "OAuth state mismatch (CSRF protection)."
          end

          validate_authorization_response_issuer!(
            as_metadata: as_metadata,
            iss: returned_iss,
            iss_provided: callback_result.length >= 3,
          )

          tokens = exchange_authorization_code(
            as_metadata: as_metadata,
            client_info: client_info,
            code: code,
            code_verifier: pkce[:code_verifier],
            resource: resource,
          )

          save_tokens_issued_by(tokens, as_metadata: as_metadata)
          :authorized
        end

        # Runs the OAuth 2.1 `client_credentials` grant (machine-to-machine, no user interaction) and persists
        # the resulting token. Shares the same discovery and security checks as `run!`; the only difference is
        # the grant exchanged at the token endpoint. There is no PKCE, redirect, or authorization request,
        # and no `offline_access` augmentation because the grant is not expected to issue a refresh token (OAuth 2.1 Section 4.3.3).
        # The pre-registered `client_id` / `client_secret` come from the provider's stored `client_information`.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
        def run_client_credentials!(as_metadata:, prm:, resource:, scope:, server_url:)
          client_info = client_credentials_client_info
          ensure_client_credentials_issuer!(client_info, as_metadata: as_metadata)

          form = { "grant_type" => "client_credentials" }
          effective_scope = resolve_scope(scope: scope, prm: prm)
          authorize_request!(as_metadata: as_metadata, scope: effective_scope, server_url: server_url, resource: resource)
          form["scope"] = effective_scope if effective_scope
          form["resource"] = resource if resource

          tokens = post_to_token_endpoint(as_metadata: as_metadata, client_info: client_info, form: form)
          save_tokens_issued_by(tokens, as_metadata: as_metadata)

          :authorized
        end

        # Reads the pre-registered credentials for the `client_credentials` grant directly from the provider's stored
        # `client_information`, rather than going through `ensure_client_registered` (which targets the authorization-code
        # flow and reaches for `Provider`-only methods like `client_metadata` and `client_id_metadata_document_url`).
        # The grant is for confidential clients, so a missing `client_id` is a clean configuration error, not a fallback
        # to dynamic registration.
        def client_credentials_client_info
          info = @provider.client_information
          unless info.is_a?(Hash) && client_info_required_value(info, "client_id")
            raise AuthorizationError,
              "Cannot run the client_credentials grant: the provider has no stored `client_id`."
          end

          info
        end

        # Per SEP-2352, static machine-to-machine credentials are bound to their authorization
        # server the same way registered ones are: when the stored `client_information` records
        # an `issuer` that differs from the current authorization server, surface an error
        # instead of silently sending another server's credentials (the spec's "SHOULD surface
        # an error"; the TypeScript SDK raises `AuthorizationServerMismatchError` here).
        # Re-registration is not an option for the `client_credentials` grant - the credentials
        # are pre-registered, not DCR results - so the operator must update the stored credentials.
        # Credentials without a recorded issuer keep working unchanged.
        def ensure_client_credentials_issuer!(client_info, as_metadata:)
          stored_issuer = client_info_required_value(client_info, "issuer")
          return if stored_issuer.nil?
          return if stored_issuer == as_metadata["issuer"]

          raise AuthorizationError,
            "Stored client credentials are bound to a different authorization server " \
              "(stored issuer #{stored_issuer.inspect}, current #{as_metadata["issuer"].inspect}); " \
              "refusing to send them to the current authorization server (SEP-2352)."
        end

        # Runs the RFC 7523 `jwt-bearer` grant for the SEP-990 Enterprise Managed Authorization extension:
        # the provider supplies an ID-JAG assertion (typically obtained from an enterprise IdP via `IDJAGTokenExchange`),
        # which is presented at the token endpoint with `client_secret_basic` authentication. Shares the same discovery
        # and security checks as `run!`; like `client_credentials`, there is no PKCE, redirect, or authorization request.
        # The assertion's audience is the issuer identifier that `ensure_issuer_matches!` validated.
        # https://github.com/modelcontextprotocol/modelcontextprotocol/issues/990
        def run_jwt_bearer!(as_metadata:, prm:, resource:, scope:, server_url:)
          client_info = @provider.client_information
          unless client_info.is_a?(Hash) && client_info_required_value(client_info, "client_id")
            raise AuthorizationError, "Cannot run the jwt-bearer grant: the provider has no stored `client_id`."
          end

          # Asked before the assertion is minted, for the same reason registration waits on the authorization-code grant:
          # obtaining an ID-JAG sends the identity provider an audience of this authorization server, which must not happen once
          # the host has refused it.
          effective_scope = resolve_scope(scope: scope, prm: prm)
          authorize_request!(as_metadata: as_metadata, scope: effective_scope, server_url: server_url, resource: resource)

          assertion = @provider.jwt_bearer_assertion(audience: as_metadata["issuer"], resource: resource)
          if assertion.nil? || assertion.to_s.empty?
            raise AuthorizationError, "The provider's assertion_provider returned no ID-JAG assertion."
          end

          form = {
            "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion" => assertion,
          }
          form["scope"] = effective_scope if effective_scope
          form["resource"] = resource if resource

          tokens = post_to_token_endpoint(as_metadata: as_metadata, client_info: client_info, form: form)
          save_tokens_issued_by(tokens, as_metadata: as_metadata)
          :authorized
        end

        # Exchanges the saved `refresh_token` for a fresh access token (RFC 6749 Section 6).
        # Re-discovers PRM and AS metadata so we always pick up a moved token endpoint, and re-runs the audience / issuer / security
        # checks before talking to it.
        #
        # Returns `:refreshed` on success. Raises `AuthorizationError` when the provider has no refresh token, no client information,
        # when a `client_credentials` or `jwt-bearer` provider's tokens record no issuer,
        # or when the token endpoint refuses the refresh request.
        # https://www.rfc-editor.org/rfc/rfc6749#section-6
        def refresh!(server_url:, resource_metadata_url: nil)
          refresh_token = read_token("refresh_token")
          raise AuthorizationError, "Cannot refresh: no refresh_token in provider storage." unless refresh_token

          ensure_refresh_token_issuer_recorded!

          stored_client_info = @provider.client_information
          have_stored_client_info = stored_client_info.is_a?(Hash) && client_info_required_value(stored_client_info, "client_id")

          # A CIMD-configured provider stores no `client_information` on purpose
          # (the CIMD URL is re-resolved against the live AS metadata on every flow).
          # Allow refresh to proceed in that case so the `refresh_token` obtained via the CIMD flow remains usable.
          have_cimd_url = !provider_client_id_metadata_document_url.nil?

          unless have_stored_client_info || have_cimd_url
            raise AuthorizationError, "Cannot refresh: no client_information in provider storage."
          end

          if resource_metadata_url
            ensure_secure_url!(resource_metadata_url, label: "WWW-Authenticate resource_metadata URL")
            ensure_same_origin!(
              resource_metadata_url,
              label: "WWW-Authenticate resource_metadata URL",
              server_url: server_url,
            )
          end

          prm, authorization_server = locate_authorization_server(
            server_url: server_url,
            resource_metadata_url: resource_metadata_url,
          )

          resource = canonical_resource(server_url: server_url, prm_resource: prm&.dig("resource"))

          as_metadata = authorization_server_metadata(
            authorization_server: authorization_server,
            legacy: prm.nil?,
            server_url: server_url,
          )

          ensure_token_issuer!(as_metadata: as_metadata)

          client_info = if have_stored_client_info
            # Pre-registered / DCR-issued `client_information` always wins: if the user picked an explicit identity,
            # do not silently swap it for the CIMD URL even when the AS also advertises CIMD support.
            ensure_refreshable_client_information!(stored_client_info, as_metadata: as_metadata)
            stored_client_info
          elsif as_metadata["client_id_metadata_document_supported"] == true
            { "client_id" => provider_client_id_metadata_document_url }
          else
            raise AuthorizationError,
              "Cannot refresh: provider has a CIMD URL but the authorization server no longer advertises " \
                "`client_id_metadata_document_supported: true`."
          end

          new_tokens = exchange_refresh_token(
            as_metadata: as_metadata,
            client_info: client_info,
            refresh_token: refresh_token,
            resource: resource,
          )

          save_tokens_issued_by(preserve_refresh_token(new_tokens, refresh_token), as_metadata: as_metadata)
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

        # Locates the authorization server for `server_url` and returns `[prm, authorization_server]`.
        #
        # Modern path (2025-06-18+): Protected Resource Metadata names the authorization server in
        # `authorization_servers`.
        #
        # Legacy path (2025-03-26 backwards compatibility): when the server publishes no PRM, `prm` is nil
        # and the MCP server's own origin acts as the authorization base URL, matching the TypeScript and Python SDKs.
        # Only a discovery answer saying that nothing usable is published (`MetadataNotPublishedError`: a `4xx` other than `429`,
        # a redirect that was not followed, or a body that is not a JSON object) selects the legacy path.
        # A request that failed to reach the server, or returned a `5xx` or `429`, says nothing about what the server publishes,
        # so once no candidate has served a usable document it is surfaced instead (`MetadataUnreachableError`),
        # as both SDKs do for network errors (the TypeScript SDK outside browsers) and the Python SDK does for server errors.
        # A body over the response cap is refused outright and never reaches the fallback either.
        # https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization#fallbacks-for-servers-without-metadata-discovery
        def locate_authorization_server(server_url:, resource_metadata_url:)
          prm = begin
            fetch_protected_resource_metadata(
              server_url: server_url,
              resource_metadata_url: resource_metadata_url,
            )
          rescue MetadataNotPublishedError
            nil
          end

          if prm
            authorization_server = first_authorization_server(prm)
            ensure_secure_url!(authorization_server, label: "PRM `authorization_servers` entry")
            ensure_routable_destination!(
              authorization_server,
              label: "PRM `authorization_servers` entry",
              server_url: server_url,
            )
            [prm, authorization_server]
          else
            authorization_base = server_origin!(server_url)
            ensure_secure_url!(authorization_base, label: "MCP server origin (legacy authorization base URL)")
            [nil, authorization_base]
          end
        end

        # Fetches and validates the authorization server's RFC 8414 metadata.
        #
        # The metadata `issuer` must be byte-identical to the discovery URL (RFC 8414 Section 3.3) on both paths.
        # On the legacy 2025-03-26 path the discovery URL is the MCP server's origin, which that spec names as
        # the authorization base URL and which a document may render with a trailing slash; the TypeScript and Python SDKs
        # accept the same slash-only difference. A document naming any other issuer is refused: an unverified `issuer`
        # would otherwise become the identity tokens and client information are bound to, assertions are minted for,
        # and the validator is shown, so a server could claim another authorization server and unlock the credentials
        # bound to it.
        # When even the metadata document is absent, the legacy spec's default endpoints are used.
        def authorization_server_metadata(authorization_server:, legacy:, server_url:)
          metadata = if legacy
            fetched = begin
              fetch_authorization_server_metadata(issuer_url: authorization_server)
            rescue AuthorizationError
              nil
            end

            if fetched
              ensure_legacy_issuer_matches!(expected: authorization_server, returned: fetched["issuer"])
              fetched
            else
              default_legacy_metadata(authorization_server)
            end
          else
            fetch_authorization_server_metadata(issuer_url: authorization_server).tap do |fetched|
              ensure_issuer_matches!(expected: authorization_server, returned: fetched["issuer"])
            end
          end

          ensure_secure_endpoints!(metadata, server_url: server_url)
          metadata
        end

        # The 2025-03-26 spec's "Fallbacks for Servers without Metadata Discovery": clients MUST use these default endpoint paths
        # relative to the authorization base URL. PKCE S256 is assumed because the legacy spec mandates PKCE and there is no metadata
        # to advertise it (the TypeScript and Python SDKs hardcode S256 on this path too).
        def default_legacy_metadata(authorization_base)
          {
            "issuer" => authorization_base,
            "authorization_endpoint" => "#{authorization_base}/authorize",
            "token_endpoint" => "#{authorization_base}/token",
            "registration_endpoint" => "#{authorization_base}/register",
            "code_challenge_methods_supported" => ["S256"],
          }
        end

        # Returns `scheme://host[:port]` of `server_url`, the legacy 2025-03-26 authorization base URL for servers without PRM.
        def server_origin!(server_url)
          uri = URI.parse(server_url.to_s)
          unless uri.is_a?(URI::HTTP) && uri.host
            raise AuthorizationError,
              "Cannot derive a legacy authorization base URL from MCP server URL #{server_url.inspect}."
          end

          port_part = uri.port == uri.default_port ? "" : ":#{uri.port}"
          "#{uri.scheme}://#{uri.host}#{port_part}"
        rescue URI::InvalidURIError => e
          raise AuthorizationError, "MCP server URL #{server_url.inspect} is not a valid URI: #{e.message}."
        end

        def fetch_authorization_server_metadata(issuer_url:)
          urls = Discovery.authorization_server_metadata_urls(issuer_url)
          fetch_metadata_json(urls, label: "authorization server metadata")
        end

        # The legacy authorization base is an origin, which a document may render as `https://host/`;
        # both name the same server, and nothing else does.
        def ensure_legacy_issuer_matches!(expected:, returned:)
          return if returned == "#{expected}/"

          ensure_issuer_matches!(expected: expected, returned: returned)
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

        # Walks candidate metadata URLs and returns the parsed body of the first 2xx response that is a JSON object;
        # the caller checks its fields. Candidates are tried until one serves such a body, since a later one may still
        # be usable when an earlier one is broken or down (the URL from `WWW-Authenticate` against the well-known path,
        # or the OAuth document against the OpenID one). Once the candidates are exhausted, an answer that said nothing
        # about what is published (a network error, a `5xx`, or a `429`) outranks the rest and raises
        # `MetadataUnreachableError`; otherwise (any other status, such as a `4xx` other than `429` or a redirect that
        # was not followed, a body that is not JSON, or not a JSON object) `MetadataNotPublishedError`.
        # A body over the cap is refused outright by `bounded_request` with a plain `AuthorizationError`,
        # before any classification. Each failure is listed with its URL stripped of userinfo, query and fragment
        # and cut to `METADATA_URL_MAX_LENGTH`, but otherwise spelled as requested, so it can be matched against
        # a server's access log, and with exception text bounded, since the message lands in every log destination
        # the error passes through.
        def fetch_metadata_json(urls, label:)
          failures = []
          inconclusive = false
          urls.each do |url|
            response = begin
              http_get(url)
            rescue Faraday::Error => e
              detail = bounded_diagnostic(e.message, limit: METADATA_DIAGNOSTIC_MAX_LENGTH)
              failures << "GET #{reported_url(url)} raised #{[e.class, detail].compact.join(": ")}"
              inconclusive = true
              next
            end

            unless response.status >= 200 && response.status < 300
              failures << "GET #{reported_url(url)} returned #{response.status}"
              inconclusive = true if response.status >= 500 || response.status == 429
              next
            end

            parsed = begin
              JSON.parse(response_body_string(response))
            rescue JSON::ParserError => e
              detail = bounded_diagnostic(e.message, limit: METADATA_DIAGNOSTIC_MAX_LENGTH) || e.class.name
              failures << "GET #{reported_url(url)} returned a body that is not JSON: #{detail}"
              next
            end

            # Even valid JSON can be the wrong shape (a top-level array, a bare `null`, a string, ...).
            # The discovery callers index by name (`prm["authorization_servers"]`, etc.), so anything that
            # is not a Hash would raise `TypeError` / `NoMethodError` downstream.
            unless parsed.is_a?(Hash)
              failures << "GET #{reported_url(url)} returned a body that is not a JSON object (got #{parsed.class})"
              next
            end

            return parsed
          end

          message = "Failed to fetch #{label}: #{failures.join("; ")}."

          if inconclusive
            raise MetadataUnreachableError, message
          else
            raise MetadataNotPublishedError, message
          end
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

        # Requires a URL the *server* chose to sit on the origin the *caller* chose.
        #
        # Protected Resource Metadata describes the MCP server itself, so on a real deployment it is
        # published on that server's own origin. Without this check a `WWW-Authenticate` challenge
        # can aim the first request of the flow at any host the client can route to: the URL arrives
        # from the network, it is fetched before the user approves anything, and the `resource` check that
        # runs afterwards cannot un-send the request.
        #
        # RFC 9728 does not itself require the metadata URL to be same-origin, so this is stricter than
        # the specification. It is enforced unconditionally because no known deployment publishes its PRM
        # anywhere else, and because the alternative (`Discovery.private_network_host?`) cannot see
        # internal hosts that are named rather than addressed.
        # https://www.rfc-editor.org/rfc/rfc9728#section-7.7
        def ensure_same_origin!(url, label:, server_url:)
          return if Discovery.same_origin?(url, server_url)

          raise AuthorizationError,
            "#{label} #{sanitized_url(url).inspect} is not on the MCP server origin " \
              "#{sanitized_url(server_url).inspect}; refusing to fetch it."
        end

        # Refuses an OAuth URL that points into a private, loopback, link-local, or unique-local address,
        # which is the SSRF precaution RFC 9728 Section 7.7 and the MCP security best practices ask clients to take.
        #
        # The carve-out matters as much as the rule: when the MCP server the caller configured is itself on such an address,
        # the whole flow is already inside that network and the authorization server legitimately lives there too.
        # That covers `http://localhost` development, the conformance harness (which runs the MCP server and
        # the authorization server on two loopback ports), and deployments that never leave a corporate network.
        # Only a server reachable on the public internet is barred from steering the client inward.
        # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
        # Hands the embedding application the authorization server and the scopes that are about to be requested,
        # and abandons the flow when it refuses them.
        #
        # Both values are chosen by the MCP server: it names its own authorization server in Protected
        # Resource Metadata and states the scopes in `scopes_supported` or the `WWW-Authenticate` challenge.
        # Neither the specification nor any MCP SDK binds that choice to the server's own identity,
        # and validating that a token was issued for the intended audience is a responsibility the specification
        # places on MCP servers rather than on clients.
        # A host that knows which providers its user deals with can apply that knowledge here.
        #
        # The scopes are passed on unchanged whatever the host decides, because the specification requires
        # a client to treat the challenged scopes as authoritative for the operation; the choice offered is
        # to proceed or to stop, not to quietly ask for less. A provider without the hook proceeds as before.
        #
        # Only asked when a new grant is being requested. A refresh is not a new grant, and the host already answered
        # this question for that authorization server, so `refresh!` enforces `ensure_token_issuer!` instead:
        # an authorization server that has changed since the tokens were issued sends the flow back through here,
        # where the host sees the new one and decides again.
        def authorize_request!(as_metadata:, scope:, server_url:, resource:)
          return unless @provider.respond_to?(:authorization_request_validator)
          return unless (validator = @provider.authorization_request_validator)

          request = AuthorizationRequest.new(
            authorization_server: as_metadata["issuer"],
            scopes: scope.to_s.split,
            server_url: server_url,
            resource: resource,
          ).freeze

          return if validator.call(request)

          raise AuthorizationRefusedError, <<~MESSAGE
            The authorization request was refused by `authorization_request_validator` \
            (authorization server #{request.authorization_server.inspect}, scopes #{request.scopes.inspect}).
          MESSAGE
        end

        def ensure_routable_destination!(url, label:, server_url:)
          return unless private_network_url?(url)
          return if private_network_url?(server_url)

          raise AuthorizationError,
            "#{label} #{sanitized_url(url).inspect} points into a private network range, " \
              "which the MCP server at #{sanitized_url(server_url).inspect} is not on; refusing to contact it."
        end

        def ensure_secure_endpoints!(as_metadata, server_url:)
          ["authorization_endpoint", "token_endpoint", "registration_endpoint"].each do |key|
            endpoint = as_metadata[key]
            next unless endpoint

            ensure_secure_url!(endpoint, label: "Authorization server #{key}")
            ensure_routable_destination!(endpoint, label: "Authorization server #{key}", server_url: server_url)
          end
        end

        # `ensure_secure_url!` runs first at every call site and already rejects a URL that fails to parse,
        # so the rescue here is a backstop rather than a leniency.
        def private_network_url?(url)
          Discovery.private_network_host?(URI.parse(url.to_s).host)
        rescue URI::InvalidURIError
          false
        end

        # Strips userinfo and query before a URL reaches an exception message, the same precaution `MCP::Client::HTTP` takes
        # when it reports a URL: these values come off the network and can carry credentials that would otherwise land in
        # every log destination the error passes through.
        def sanitized_url(url)
          Discovery.canonicalize_origin_and_path(url)
        rescue URI::Error
          url.to_s
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
          existing = stored_client_information_for(issuer: as_metadata["issuer"])
          return existing if existing

          # Per the MCP authorization specification and `draft-ietf-oauth-client-id-metadata-document`,
          # if the authorization server advertises Client ID Metadata Document support and the provider has
          # a CIMD URL configured, use the URL as the OAuth `client_id` and skip Dynamic Client Registration.
          #
          # The `== true` comparison is intentional: only a JSON `boolean` `true` opts the flow in.
          # A string `"false"`, an empty Hash, or any other truthy value MUST NOT be treated as CIMD support,
          # otherwise a misconfigured AS could trick the client into using the CIMD `client_id` against
          # a server that has not actually adopted it.
          #
          # The CIMD `client_id` is NOT persisted to storage. The AS may later stop advertising CIMD support
          # (or the operator may rotate the CIMD URL), and a stale `client_information` entry would otherwise
          # keep sending the old CIMD URL forever. Re-evaluating on every flow re-reads the current AS metadata
          # and the current `provider.client_id_metadata_document_url`.
          cimd_url = provider_client_id_metadata_document_url
          if cimd_url && as_metadata["client_id_metadata_document_supported"] == true
            return { "client_id" => cimd_url }
          end

          registration_endpoint = as_metadata["registration_endpoint"]
          unless registration_endpoint
            raise AuthorizationError,
              "Authorization server has no registration_endpoint and no pre-registered client information was provided."
          end

          response = begin
            http_post_json(registration_endpoint, registration_client_metadata)
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

          # Per SEP-2352, persisted client credentials are keyed by the issuer identifier of
          # the authorization server that minted them, so a later flow can detect an AS change and
          # re-register instead of replaying another server's credentials. `issuer` is not an RFC 7591 response field;
          # the SDK adds it to the opaque persisted hash.
          @provider.save_client_information(info.merge("issuer" => as_metadata["issuer"]))

          info
        end

        # Returns the client metadata to submit on Dynamic Client Registration.
        # Per SEP-837, MCP clients MUST specify an appropriate OIDC `application_type`
        # so the authorization server can apply the matching redirect URI policy.
        # When the user did not set one explicitly, infer `"native"` vs `"web"` from
        # the registered `redirect_uris`; an explicit value always wins.
        # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/837
        def registration_client_metadata
          metadata = @provider.client_metadata
          return metadata if metadata[:application_type] || metadata["application_type"]

          redirect_uris = metadata[:redirect_uris] || metadata["redirect_uris"]
          metadata.merge("application_type" => Discovery.infer_application_type(redirect_uris))
        end

        # Returns the stored `client_information` when it may be used against the authorization server
        # identified by `issuer`, applying SEP-2352's authorization server binding rules:
        #
        # - Credentials persisted with an `"issuer"` binding MUST NOT be reused against
        #   a different authorization server. When the AS changed, the stale registration and its tokens
        #   are discarded (tokens minted by the old AS are dead at the new one) and nil is returned so
        #   the flow re-registers.
        # - Stored credentials without an `"issuer"` binding (data persisted by an older SDK version,
        #   or user-supplied pre-registered credentials) are bound to the current issuer on first use.
        # - A CIMD `client_id` (an HTTPS URL) is portable across authorization servers, so it is reused
        #   and re-bound instead of discarded.
        #
        # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2352
        def stored_client_information_for(issuer:)
          existing = @provider.client_information
          return unless existing.is_a?(Hash) && client_info_required_value(existing, "client_id")

          stored_issuer = client_info_required_value(existing, "issuer")
          return existing if stored_issuer == issuer
          return rebind_client_information(existing, issuer: issuer) if stored_issuer.nil?

          client_id = client_info_required_value(existing, "client_id")
          return rebind_client_information(existing, issuer: issuer) if Discovery.client_id_metadata_document_url?(client_id)

          @provider.save_client_information(nil)
          @provider.clear_tokens!
          nil
        end

        def rebind_client_information(info, issuer:)
          rebound = info.merge("issuer" => issuer)
          @provider.save_client_information(rebound)
          rebound
        end

        # Per SEP-2352, stored client credentials are bound to the authorization server that issued them;
        # refuse to replay another AS's credentials at this token endpoint. `HTTP#attempt_refresh` rescues
        # the error and falls back to the full flow, which discards the stale registration and re-registers.
        # Credentials without an `"issuer"` binding predate this check and are allowed through;
        # CIMD `client_id`s are portable.
        # Records which authorization server minted these tokens, alongside the tokens themselves.
        # SEP-2352 already binds *client credentials* to their issuer; this binds the *tokens*, which that
        # SEP leaves unbound.
        # Stored in the token hash so it travels through any `storage` a caller supplied, without widening
        # the storage interface that custom implementations have to satisfy.
        def save_tokens_issued_by(tokens, as_metadata:)
          issuer = as_metadata["issuer"]
          tokens = tokens.merge("issuer" => issuer) if tokens.is_a?(Hash) && issuer

          @provider.save_tokens(tokens)
        end

        # Refuses to present a refresh token to an authorization server other than the one that issued it.
        # `refresh!` rediscovers the authorization server from Protected Resource Metadata every time,
        # so the server named for a session can differ from the one the stored tokens came from.
        # Unlike `ensure_refreshable_client_information!` this holds whatever the client identity is,
        # including a Client ID Metadata Document URL, which is portable across authorization servers precisely
        # so that re-registration is unnecessary.
        #
        # Tokens stored before this shipped carry no issuer and are left alone, matching how SEP-2352 treats
        # client information without one; the binding takes effect from their next authorization.
        # The caller answers a refusal by running the full authorization flow, which is where the embedding application
        # is asked about the new authorization server.
        def ensure_token_issuer!(as_metadata:)
          stored_issuer = read_token("issuer")
          return if stored_issuer.nil? || stored_issuer == as_metadata["issuer"]

          raise AuthorizationError, <<~MESSAGE
            Cannot refresh: the stored tokens were issued by a different authorization server (stored issuer #{stored_issuer.inspect}, \
            current #{as_metadata["issuer"].inspect}); re-authorization is required.
          MESSAGE
        end

        # `Provider` tolerates tokens stored before the issuer was recorded (see `ensure_token_issuer!`).
        # The `client_credentials` and `jwt-bearer` providers have no such tokens, since their refresh is new,
        # and a refresh asks no validator, so a token without an `issuer` would be presented to whatever
        # authorization server discovery names now. Refusing it sends the transport back through the grant,
        # which does ask.
        def ensure_refresh_token_issuer_recorded!
          return if provider_authorization_flow == :authorization_code
          return unless read_token("issuer").nil?

          raise AuthorizationError, "Cannot refresh: the stored tokens record no issuer; re-authorization is required."
        end

        def ensure_refreshable_client_information!(client_info, as_metadata:)
          stored_issuer = client_info_required_value(client_info, "issuer")
          return if stored_issuer.nil?
          return if stored_issuer == as_metadata["issuer"]

          client_id = client_info_required_value(client_info, "client_id")
          return if Discovery.client_id_metadata_document_url?(client_id)

          raise AuthorizationError,
            "Cannot refresh: stored client credentials were issued by a different authorization server " \
              "(stored issuer #{stored_issuer.inspect}, current #{as_metadata["issuer"].inspect}); " \
              "re-registration is required (SEP-2352)."
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

        # Validates the RFC 9207 `iss` authorization response parameter against the issuer of the authorization server
        # the flow is talking to, per SEP-2468 (mix-up attack mitigation in multi-IdP setups):
        #
        # - When the callback supplied a non-empty `iss`, it MUST equal the AS metadata `issuer` exactly (simple string comparison,
        #   no normalization, per RFC 9207 Section 2.4); on mismatch the flow aborts before the authorization code is ever sent to
        #   a token endpoint.
        # - When the callback returned a 3-element `[code, state, iss]` whose `iss` is nil (asserting it inspected the authorization response
        #   and found no `iss`) and the AS metadata advertises `authorization_response_iss_parameter_supported: true`, the missing parameter
        #   is treated as an attack per RFC 9207 Section 2.4 and the flow aborts.
        # - A legacy 2-element `[code, state]` callback skips the check: the caller never looked for `iss`, so its absence carries no signal.
        #
        # `as_metadata["issuer"]` has already been byte-compared against the discovery URL by `ensure_issuer_matches!`,
        #  so it is the RFC 9207 anchor value. `iss` is not a secret; a plain `==` suffices.
        #
        # - https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2468
        # - https://www.rfc-editor.org/rfc/rfc9207
        def validate_authorization_response_issuer!(as_metadata:, iss:, iss_provided:)
          expected = as_metadata["issuer"]

          if iss && !iss.to_s.empty?
            return if iss.to_s == expected.to_s

            raise AuthorizationError,
              "Authorization response `iss` does not match the authorization server issuer " \
                "(expected #{expected.inspect}, got #{iss.inspect}) (RFC 9207); " \
                "refusing to exchange the authorization code."
          end

          return unless iss_provided
          return unless as_metadata["authorization_response_iss_parameter_supported"] == true

          raise AuthorizationError,
            "Authorization server advertises `authorization_response_iss_parameter_supported` but " \
              "the authorization response carried no `iss` parameter (RFC 9207 Section 2.4); " \
              "refusing to exchange the authorization code."
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

          # `prm` is nil on the legacy path, where nothing advertises scopes.
          supported = prm && prm["scopes_supported"]
          return supported.join(" ") if supported.is_a?(Array) && !supported.empty?

          return @provider.scope if @provider.scope && !@provider.scope.empty?

          nil
        end

        # Applies the SDK's `offline_access` policy to the resolved scope. The policy has two halves:
        #
        # - Spec (SEP-2207): a client that wants a refresh token (signalled here by listing
        #   `refresh_token` in its registered `grant_types`) MAY request `offline_access`
        #   when the authorization server advertises it in metadata `scopes_supported`.
        #   When the server advertises it and the client opted in, add it if absent.
        #
        # - SDK policy (defensive hardening): when the server does NOT advertise `offline_access`,
        #   strip it from the resolved scope no matter where it came from (the `WWW-Authenticate` challenge,
        #   PRM `scopes_supported`, or the provider-supplied scope). SEP-2207 only says clients SHOULD NOT
        #   request unsupported scopes, but a misbehaving RS that includes `offline_access` in its challenge,
        #   or a misconfigured PRM that lists it under `scopes_supported`, would otherwise propagate into
        #   the authorization request even though the AS will not honour it. Stripping here keeps the SDK's
        #   own request consistent with the AS's advertisement.
        #
        # Returns `nil` when the result is empty so `build_authorization_url` omits the `scope` parameter entirely.
        # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2207
        def normalize_offline_access_scope(scope, as_metadata:)
          scopes = scope.to_s.split

          if server_supports_offline_access?(as_metadata)
            scopes << "offline_access" if wants_refresh_token? && !scopes.include?("offline_access")
          else
            scopes.delete("offline_access")
          end

          scopes.empty? ? nil : scopes.join(" ")
        end

        def server_supports_offline_access?(as_metadata)
          supported = as_metadata["scopes_supported"]

          supported.is_a?(Array) && supported.include?("offline_access")
        end

        def wants_refresh_token?
          metadata = @provider.client_metadata
          grant_types = metadata[:grant_types] || metadata["grant_types"]

          Array(grant_types).include?("refresh_token")
        end

        # The OAuth flow the provider drives. Dispatching on the provider's
        # declared flow keeps `Flow` from second-guessing intent by parsing
        # `client_metadata[:grant_types]` (which is protocol metadata for the
        # authorization server, not an SDK control signal). A provider that
        # predates this method is treated as the interactive authorization-code
        # flow it was the only option for.
        def provider_authorization_flow
          return :authorization_code unless @provider.respond_to?(:authorization_flow)

          @provider.authorization_flow
        end

        # Parameters the provider adds to every token request it makes (RFC 6749 Section 8.2 leaves room for them;
        # Auth0's `audience` is the usual one). Duck-typed like `authorization_flow`, so a provider without the method,
        # or one returning `nil`, adds nothing.
        # A bad value raises `InvalidTokenRequestParamsError`, as the provider constructors do.
        def provider_token_request_params
          return {} unless @provider.respond_to?(:token_request_params)

          params = @provider.token_request_params
          return {} if params.nil?

          problem = self.class.token_request_params_problem(params)
          raise InvalidTokenRequestParamsError, "The provider's token_request_params #{problem}" if problem

          params
        end

        # The Client ID Metadata Document URL, when the provider has one. Only `Provider` exposes the reader
        # (CIMD replaces Dynamic Client Registration on the authorization-code flow), while `refresh!` serves
        # every provider that holds a `refresh_token`, so the read is duck-typed like `authorization_flow`.
        def provider_client_id_metadata_document_url
          return unless @provider.respond_to?(:client_id_metadata_document_url)

          @provider.client_id_metadata_document_url
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

        # Submits a form-encoded token request using the authentication method
        # stored in `client_information`. The method determines whether client
        # credentials belong in the form body, a Basic header, or a JWT assertion.
        # A provider's `token_request_params` go underneath the flow's own parameters,
        # which therefore win, and are refused before the request is sent when they name
        # a reserved parameter or are not a Hash of Strings.
        def post_to_token_endpoint(as_metadata:, client_info:, form:)
          client_id = client_info_required_value(client_info, "client_id")
          unless client_id
            raise AuthorizationError,
              "Cannot post to token endpoint: client_information is missing `client_id`."
          end

          client_secret = client_info_required_value(client_info, "client_secret")
          token_endpoint_auth_method = client_info_value(client_info, "token_endpoint_auth_method")
          form = provider_token_request_params.merge(form)

          # Apply one client authentication method per request (RFC 6749 Section 2.3).
          headers = {}
          form = case token_endpoint_auth_method
          when "private_key_jwt"
            # The assertion identifies the client through its `iss` and `sub`
            # claims, so the body needs no separate `client_id` (RFC 7521 Section 4.2).
            # Use the issuer already checked by `ensure_issuer_matches!` as the audience.
            unless @provider.respond_to?(:client_assertion)
              raise AuthorizationError,
                "token_endpoint_auth_method is private_key_jwt but the provider does not " \
                  "implement `client_assertion(audience:)`."
            end

            form.merge(
              "client_assertion_type" => JWTClientAssertion::ASSERTION_TYPE,
              "client_assertion" => @provider.client_assertion(audience: as_metadata["issuer"]),
            )
          when "client_secret_post"
            # Send the client ID and available secret in the form body.
            body = form.merge("client_id" => client_id)
            body["client_secret"] = client_secret if client_secret
            body
          else
            if client_secret && token_endpoint_auth_method != "none"
              # Basic is also the fallback when a secret is present but no method
              # is stored. A body `client_id` is optional (RFC 6749 Section 3.2.1);
              # omit it because some servers treat it alongside Basic as a second
              # authentication method and reject the request with `invalid_request`.
              headers["Authorization"] = "Basic " + basic_auth_credentials(client_id, client_secret)
              form
            else
              # With `none` or no secret, identify the client using `client_id`.
              # This is required for unauthenticated authorization-code exchanges
              # (RFC 6749 Section 3.2.1).
              form.merge("client_id" => client_id)
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
            raise token_endpoint_error(response)
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

        # Surface only RFC 6749 §5.2 diagnostic fields, never the raw response,
        # which may contain tokens or other credentials. Classify the original
        # code so sanitization cannot turn malformed input into invalid_grant.
        def token_endpoint_error(response)
          message = "Token endpoint returned status #{response.status}."
          error_class = AuthorizationError
          parsed = JSON.parse(response_body_string(response))
          parsed = {} unless parsed.is_a?(Hash)

          error_class = parsed["error"] == "invalid_grant" ? InvalidGrantError : AuthorizationError
          error = bounded_diagnostic(parsed["error"], limit: TOKEN_ENDPOINT_ERROR_MAX_LENGTH)
          description = bounded_diagnostic(parsed["error_description"], limit: TOKEN_ENDPOINT_ERROR_DESCRIPTION_MAX_LENGTH)
          message += " #{[error, description].compact.join(": ")}" if error || description

          error_class.new(message, http_status: response.status, error: error, error_description: description)
        rescue StandardError
          # Diagnostics must not mask the endpoint failure or change refresh recovery.
          error_class.new("Token endpoint returned status #{response.status}.", http_status: response.status)
        end

        def bounded_diagnostic(value, limit:)
          return unless value.is_a?(String)

          # RFC 6749 permits printable ASCII except double quotes and backslashes in token endpoint error fields.
          # Replace other characters to keep text received off the network on one log line.
          value = value.scrub(" ").gsub(/[^\x20-\x21\x23-\x5B\x5D-\x7E]/, " ").strip
          return if value.empty?

          value.length > limit ? "#{value[0, limit - 3]}..." : value
        end

        # A candidate URL as it goes into a failure string: redacted, and cut so a URL the server chose cannot
        # grow the message without limit.
        def reported_url(url)
          bounded_diagnostic(Discovery.redact_url(url), limit: METADATA_URL_MAX_LENGTH)
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
          bounded_request do |on_data|
            http_client.get(url) do |req|
              req.options.on_data = on_data
            end
          end
        end

        def http_post_json(url, body)
          bounded_request do |on_data|
            http_client.post(url) do |req|
              req.headers["Content-Type"] = "application/json"
              req.headers["Accept"] = "application/json"
              req.options.on_data = on_data
              req.body = JSON.generate(body)
            end
          end
        end

        def http_post_form(url, form, headers: {})
          bounded_request do |on_data|
            http_client.post(url) do |req|
              req.headers["Content-Type"] = "application/x-www-form-urlencoded"
              req.headers["Accept"] = "application/json"

              headers.each do |key, value|
                req.headers[key] = value
              end

              req.options.on_data = on_data
              req.body = URI.encode_www_form(form)
            end
          end
        end

        # Issues a request with the response body bounded as it arrives, and returns the status paired with
        # that body. An over-cap response is refused rather than truncated: a partial discovery or token document
        # cannot be validated, and `fetch_metadata_json` must not fall through to the next candidate URL either,
        # since the same server would serve the same body.
        def bounded_request
          bounded = BoundedBody.new

          response = yield(bounded.on_data)

          bounded.response_for(response)
        rescue BoundedBody::TooLargeError => e
          raise AuthorizationError, "#{e.message}."
        end

        def http_client
          @http_client ||= @http_client_factory.call
        end

        # A connection supplied through `http_client_factory:` replaces this one, the provider's customizer and
        # `RequestedOriginGuard` included, so that caller takes on the redirect responsibility described on
        # `build_http_client`; `bounded_request` caps its responses all the same.
        def default_http_client
          self.class.build_http_client(provider_http_client_customizer)
        end

        # `nil` for a provider that predates the hook or leaves it unset.
        def provider_http_client_customizer
          return unless @provider.respond_to?(:http_client_customizer)

          @provider.http_client_customizer
        end

        def response_body_string(response)
          body = response.body
          body.is_a?(String) ? body : body.to_s
        end
      end
    end
  end
end
