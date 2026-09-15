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

        attr_reader :resource, :authorization_servers, :scopes_supported, :resource_name, :resource_documentation, :bearer_methods_supported, :extra

        def initialize(resource:, authorization_servers:, scopes_supported: nil, resource_name: nil, resource_documentation: nil, bearer_methods_supported: DEFAULT_BEARER_METHODS_SUPPORTED, extra: {})
          @resource_uri = parse_resource_uri(resource)
          @resource = resource

          servers = Array(authorization_servers)
          raise ArgumentError, "authorization_servers must contain at least one issuer URL" if servers.empty?

          servers.each do |server|
            next if Client::OAuth::Discovery.secure_url?(server)

            raise ArgumentError, "authorization_servers must use https (http is allowed only on loopback): #{server.inspect}"
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

          unless Client::OAuth::Discovery.secure_url?(resource.to_s)
            raise ArgumentError, "resource must use https (http is allowed only on loopback): #{resource.inspect}"
          end

          uri
        end
      end
    end
  end
end
