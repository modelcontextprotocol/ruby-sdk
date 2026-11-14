# frozen_string_literal: true

require "json"
require "uri"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module OAuth
      # OAuth 2.0 Protected Resource Metadata (RFC 9728) for an MCP server.
      # The MCP authorization spec requires servers to publish this document so clients can discover which authorization servers can
      # issue tokens for the resource.
      #
      # - `resource` - the canonical resource identifier: the URL clients connect to, without a fragment. Clients send this back to
      #   the authorization server as the RFC 8707 `resource` parameter.
      # - `authorization_servers` - issuer URLs of the authorization servers that protect this resource (at least one).
      # - `scopes_supported` - an Array of the scope strings clients may request (also the default scope hint in `WWW-Authenticate` challenges);
      #   `offline_access` is dropped, and a result with nothing left omits the member.
      # - `bearer_methods_supported` - defaults to `["header"]`: the SDK accepts bearer tokens only in the `Authorization` header,
      #   never in a query string.
      # - `extra` - additional RFC 9728 fields (e.g. `jwks_uri`, `resource_signing_alg_values_supported`, `resource_policy_uri`) merged into
      #   the document as given; the members above cannot be overridden through it.
      #
      # https://www.rfc-editor.org/rfc/rfc9728
      # https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery
      class ProtectedResourceMetadata
        WELL_KNOWN_PATH_PREFIX = "/.well-known/oauth-protected-resource"

        DEFAULT_BEARER_METHODS_SUPPORTED = ["header"].freeze
        private_constant :DEFAULT_BEARER_METHODS_SUPPORTED

        # The members `initialize` validates. `extra` may not name them, or the merge in `to_h` would undo the validation.
        VALIDATED_MEMBERS = ["resource", "authorization_servers", "scopes_supported", "resource_name", "resource_documentation", "bearer_methods_supported"].freeze
        private_constant :VALIDATED_MEMBERS

        # One or more host name labels in front of `localhost`.
        LOCALHOST_SUBDOMAIN = /\A(?:[a-z0-9-]+\.)+localhost\z/.freeze
        private_constant :LOCALHOST_SUBDOMAIN

        attr_reader :resource, :authorization_servers, :scopes_supported, :resource_name, :resource_documentation, :bearer_methods_supported, :extra

        def initialize(resource:, authorization_servers:, scopes_supported: nil, resource_name: nil, resource_documentation: nil, bearer_methods_supported: DEFAULT_BEARER_METHODS_SUPPORTED, extra: {})
          @resource_uri = parse_resource_uri(resource)
          @resource = resource

          servers = Array(authorization_servers)
          raise ArgumentError, "authorization_servers must contain at least one issuer URL" if servers.empty?

          servers.each do |server|
            next if secure_identifier?(server)

            raise ArgumentError, "authorization_servers must use https (http is allowed only on loopback or a name under localhost): #{server.inspect}"
          end

          overridden = extra.keys.map(&:to_s) & VALIDATED_MEMBERS
          unless overridden.empty?
            raise ArgumentError, "extra must not override #{overridden.join(", ")}; pass them as keyword arguments so they are validated"
          end

          @authorization_servers = servers
          @scopes_supported = advertisable_scopes(scopes_supported)
          @resource_name = resource_name
          @resource_documentation = resource_documentation
          @bearer_methods_supported = bearer_methods_supported
          @extra = extra
        end

        def to_h
          {
            resource: resource,
            authorization_servers: authorization_servers,
            scopes_supported: scopes_supported,
            resource_name: resource_name,
            resource_documentation: resource_documentation,
            bearer_methods_supported: bearer_methods_supported,
          }.compact.merge(extra)
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        # The path-inserted well-known path per RFC 9728 Section 3: a resource of `https://example.com/mcp` is described at
        # `/.well-known/oauth-protected-resource/mcp`, and a resource at the origin root is described at `/.well-known/oauth-protected-resource`.
        # The path math intentionally matches what `MCP::Client::OAuth::Discovery.protected_resource_metadata_urls` probes.
        def well_known_path
          path = @resource_uri.path
          path = "" if path == "/"

          "#{WELL_KNOWN_PATH_PREFIX}#{path}"
        end

        # The absolute URL of the metadata document. Pass this to `Middleware` (or `Challenge`) as `resource_metadata_url` so 401/403 challenges point
        # clients at the document.
        def well_known_url
          port = @resource_uri.port && @resource_uri.port != @resource_uri.default_port ? ":#{@resource_uri.port}" : ""

          "#{@resource_uri.scheme}://#{@resource_uri.host}#{port}#{well_known_path}"
        end

        private

        # The MCP authorization specification tells protected resources not to advertise `offline_access`: refresh token issuance
        # is the authorization server's business, not a resource requirement. `Authenticator` already drops it from the `scope` parameter of
        # a `WWW-Authenticate` challenge, so dropping it here keeps the document and the challenges saying the same thing.
        # https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
        # Nothing left to advertise drops the member from the document instead of emitting `[]`, which RFC 9728 tells servers to omit,
        # and a non-Array is refused because a bare String would be ambiguous between one scope and a list.
        def advertisable_scopes(scopes_supported)
          return if scopes_supported.nil?
          raise ArgumentError, "scopes_supported must be an Array of scope strings" unless scopes_supported.is_a?(Array)

          scopes = scopes_supported.map(&:to_s) - ["offline_access"]

          scopes.empty? ? nil : scopes
        end

        def parse_resource_uri(resource)
          uri = begin
            URI.parse(resource.to_s)
          rescue URI::InvalidURIError
            raise ArgumentError, "resource must be a valid URI: #{resource.inspect}"
          end

          unless ["http", "https"].include?(uri.scheme.to_s.downcase) && uri.host && !uri.host.empty?
            raise ArgumentError, "resource must be an absolute http(s) URL: #{resource.inspect}"
          end

          if uri.fragment
            raise ArgumentError, "resource must not contain a fragment per RFC 8707: #{resource.inspect}"
          end

          unless secure_identifier?(resource.to_s)
            raise ArgumentError, "resource must use https (http is allowed only on loopback or a name under localhost): #{resource.inspect}"
          end

          uri
        end

        # Whether `url` may stand in this document: what `Discovery.secure_url?` admits, and plain `http` on a name under
        # `localhost` (`http://acme.localhost:3000/mcp`), the way a server that gives each tenant a subdomain is run in development.
        #
        # The wider rule is for these two members only, because this server never connects to them: `resource` is published
        # and compared with a token's audience, `authorization_servers` is published and compared with its issuer.
        # Such a name is reserved for loopback and cannot be registered (RFC 6761 Section 6.3),
        # but a resolver is not bound to answer it with the loopback address, which is why `secure_url?`, the check for
        # a URL that is connected to (`jwks_uri:`, `introspection_endpoint:`, everything in the client), keeps to `localhost` itself.
        # The host is read from the parsed URL, so `x.localhost.example.com` and `x.localhost@example.com` are ordinary names,
        # and it has to be made of host name labels: `URI` leaves a percent-encoded host as written,
        # and `example.com%2F.localhost` would otherwise end the right way.
        def secure_identifier?(url)
          return true if Client::OAuth::Discovery.secure_url?(url)

          uri = URI.parse(url.to_s)
          return false unless uri.scheme&.downcase == "http"

          uri.host.to_s.downcase.delete_suffix(".").match?(LOCALHOST_SUBDOMAIN)
        rescue URI::InvalidURIError
          false
        end
      end
    end
  end
end
