# frozen_string_literal: true

require "ipaddr"
require "uri"

module MCP
  class Client
    module OAuth
      # Stateless helpers that map MCP-authorization spec URLs and headers into something
      # the `Flow` orchestrator and `MCP::Client::HTTP` transport can act on.
      # The module bundles five concerns that share no state but are closely related to
      # the spec's "Discovery" and "Communication Security" sections:
      #
      # - **`WWW-Authenticate` parsing** (`parse_www_authenticate`): pulls
      #   the Bearer challenge parameters (`resource_metadata`, `scope`, `error`,
      #   ...) out of a header that may carry multiple challenges per RFC 7235
      #   and may use `quoted-pair` escapes per RFC 7230 Section 3.2.6.
      # - **Discovery URL builders** (`protected_resource_metadata_urls`,
      #   `authorization_server_metadata_urls`): list the candidate well-known
      #   URLs to probe when no explicit metadata URL is supplied,
      #   in the priority order required by RFC 9728 and RFC 8414.
      # - **Communication Security check** (`secure_url?`): enforces "HTTPS only"
      #   for every OAuth-facing URL, with the loopback carve-out described in
      #   `secure_url?`'s comment.
      # - **URL canonicalization** (`canonicalize_url`): normalizes scheme,
      #   host, port, path, percent-encoded dot segments, and fragments
      #   so two URLs that *refer to the same resource* compare as equal,
      #   and drops userinfo so credentials never reach the RFC 8707 `resource` claim
      #   or any error message.
      # - **Resource coverage** (`resource_covers?`): decides whether a PRM `resource` URI
      #   is allowed to govern a given MCP server URL, i.e. whether the MCP endpoint sits
      #   "under" the resource per RFC 8707 audience semantics.
      #
      # Every entry point is a class method so it can be called from initializers and
      # from any thread without synchronization.
      module Discovery
        # Matches a single `key=value` pair inside an HTTP auth-scheme challenge.
        # `value` is either a quoted string (which can contain commas and spaces)
        # or a bare token, per RFC 7235.
        WWW_AUTH_PARAM_PATTERN = /\A([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))/

        class << self
          # Parses a `WWW-Authenticate` header and returns the parameters of
          # the `Bearer` challenge as a hash with lower-cased keys (e.g. `resource_metadata`,
          # `scope`, `error`). Returns `{}` when no Bearer challenge is present.
          # Handles multiple challenges (e.g. `Basic ..., Bearer ...` or `Bearer ..., DPoP ...`)
          # by extracting only the Bearer parameters.
          #
          # - https://www.rfc-editor.org/rfc/rfc9728.html#section-5.1
          # - https://www.rfc-editor.org/rfc/rfc7235.html#section-4.1
          def parse_www_authenticate(header)
            return {} unless header

            # Locate the Bearer challenge: at the start of the header or after a comma.
            bearer = header.match(/(?:\A|,)\s*Bearer(?:\s+|\z)/i)
            return {} unless bearer

            # Walk key=value pairs starting where Bearer's parameters begin.
            # The loop stops at the first token that is not a key=value pair,
            # which marks the next challenge (e.g. `, DPoP algs="..."`).
            cursor = bearer.end(0)
            params = {}
            while cursor < header.length
              prefix = header[cursor..]
              prefix = prefix.sub(/\A\s*,?\s*/, "")
              break if prefix.empty?

              match = prefix.match(WWW_AUTH_PARAM_PATTERN)
              break unless match

              params[match[1].downcase] = match[2] ? unescape_quoted_pair(match[2]) : match[3]
              cursor = header.length - prefix.length + match.end(0)
            end
            params
          end

          # Returns the candidate Protected Resource Metadata URLs to probe, in priority order.
          # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#protected-resource-metadata-discovery-requirements
          def protected_resource_metadata_urls(server_url:, resource_metadata_url: nil)
            urls = []
            urls << resource_metadata_url if resource_metadata_url

            uri = URI.parse(server_url)
            path = uri.path == "/" ? "" : uri.path.to_s
            base = base_url(uri)

            urls << "#{base}/.well-known/oauth-protected-resource#{path}"
            urls << "#{base}/.well-known/oauth-protected-resource"
            urls.uniq
          end

          # Returns the candidate Authorization Server metadata URLs to probe, in priority order.
          #
          # Per SEP-2351, MCP uses the default `oauth-authorization-server` well-known URI suffix
          # registered by RFC 8414 Section 7.3 and defines no application-specific suffix of its own.
          # The OAuth candidates below therefore use only that default suffix
          # (plus the `openid-configuration` suffix from OpenID Connect Discovery),
          # both in the RFC 8414 Section 3.1 path-inserted form for issuers with a path component
          # and in the root form for issuers without one.
          #
          # - https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#authorization-server-metadata-discovery
          # - https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2351
          # - https://www.rfc-editor.org/rfc/rfc8414#section-3.1
          def authorization_server_metadata_urls(issuer_url)
            uri = URI.parse(issuer_url)
            path = uri.path == "/" ? "" : uri.path.to_s
            base = base_url(uri)

            if path.empty?
              ["#{base}/.well-known/oauth-authorization-server", "#{base}/.well-known/openid-configuration"]
            else
              [
                "#{base}/.well-known/oauth-authorization-server#{path}",
                "#{base}/.well-known/openid-configuration#{path}",
                "#{base}#{path}/.well-known/openid-configuration",
              ]
            end
          end

          # Returns a canonical form of `url` suitable for comparing two URIs
          # that are meant to identify the same protected resource: lowercased scheme/host,
          # default port stripped, fragment removed, percent-encoded dot octets normalized
          # to `.` per RFC 3986 Section 6.2.2.2, dot-segments in the path resolved per
          # RFC 3986 Section 5.2.4, and a single trailing `/` on the root path normalized away.
          #
          # Userinfo is *dropped*. The MCP authorization spec sends the canonicalized URL
          # on the wire as the RFC 8707 `resource` claim and surfaces it in error messages;
          #  both paths would leak `user:pass@` credentials to the authorization server and
          # to log destinations if we preserved them. The MCP server URI does not legitimately
          # carry userinfo, so dropping it is also a no-op for normal traffic.
          #
          # Decoding `%2e`/`%2E` *before* dot-segment resolution is what prevents
          # an attacker-supplied URL like `https://srv.example.com/api/%2e%2e/mcp` from sneaking
          # past the PRM `resource` check in `resource_covers?`.
          def canonicalize_url(url)
            uri = URI.parse(url.to_s)

            uri.fragment = nil
            # `URI::Generic#userinfo=` is a no-op on Ruby 2.7 (the project's minimum supported version),
            # so clear the components individually.
            if uri.respond_to?(:user) && (uri.user || uri.password)
              uri.user = nil
              uri.password = nil
            end
            uri.scheme = uri.scheme.downcase if uri.scheme
            uri.host = uri.host.downcase if uri.host
            uri.port = nil if uri.port == uri.default_port

            path = uri.path.to_s.gsub(/%2[eE]/, ".")
            uri.path = remove_dot_segments(path)
            uri.path = "" if uri.path == "/"

            uri.query = normalize_query(uri.query)

            uri.to_s
          end

          # Returns true when `url` is safe to use for OAuth communication per
          # the MCP authorization spec's "Communication Security" requirement:
          # `https` is always allowed, `http` is permitted only when the host is
          # a loopback address (`localhost`, `127.0.0.0/8`, or `::1`).
          #
          # The loopback exception applies uniformly to every OAuth-related URL
          # the SDK consumes (PRM URL, AS metadata URL, `authorization_servers`
          # entries, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`,
          # the `redirect_uri`, and the MCP transport URL when `oauth:` is set).
          # A strict reading of OAuth 2.1 reserves the loopback carve-out for
          # `redirect_uri` only (per RFC 8252), but neither the Python nor
          # the TypeScript MCP SDK enforces HTTPS on those endpoints either -
          # and the official MCP conformance test suite drives its fixtures
          # over `http://localhost` auth servers, so enforcing HTTPS for everything
          # except `redirect_uri` would break local development out of the box and
          # regress 16 conformance scenarios. Operators who run in production are
          # expected to deploy real HTTPS endpoints; this helper does not enforce
          # that at the SDK boundary.
          #
          # Rejects URLs that fail to parse, lack a host, or whose `http://` host is
          # something like `127.attacker.com` or `foo.localhost`,
          # which would otherwise pass a naive `start_with?("127.")` check.
          # https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#communication-security
          def secure_url?(url)
            return false if url.nil? || url.to_s.empty?

            uri = URI.parse(url.to_s)
            return false if uri.host.nil? || uri.host.empty?

            scheme = uri.scheme&.downcase
            return true if scheme == "https"
            return loopback_host?(uri.host) if scheme == "http"

            false
          rescue URI::InvalidURIError
            false
          end

          # Returns true when `url` satisfies the structural requirements for
          # a Client ID Metadata Document URL per the MCP 2025-11-25
          # authorization specification and `draft-ietf-oauth-client-id-metadata-document-00`.
          #
          # Spec-required:
          #
          # - scheme MUST be `https` (the loopback-`http` carve-out used for discovery does not apply:
          #   the document URL is sent verbatim to the authorization server as the OAuth `client_id`
          #   and travels off-loopback)
          # - host MUST be present
          # - path MUST be non-empty and MUST NOT be the root (`/`); the document is a discrete resource,
          #   not the origin
          # - URL MUST NOT carry a fragment or userinfo: a fragment is not sent to the server, and userinfo
          #   would leak credentials into every `client_id` log line
          # - path MUST be already free of `.` / `..` dot segments after percent-decoding, so two URLs with
          #   the same effective path do not produce different `client_id` strings
          #
          # SDK policy (stricter than the draft):
          #
          # - URL MUST NOT carry a query string. The draft marks query components only SHOULD NOT include,
          #   but different encodings of the same query (`?a=1&b=2` vs `?b=2&a=1`) would yield distinct
          #   `client_id` values for the same logical document.
          def client_id_metadata_document_url?(url)
            return false if url.nil? || url.to_s.empty?

            uri = URI.parse(url.to_s)
            return false unless uri.scheme&.downcase == "https"
            return false if uri.host.nil? || uri.host.empty?
            return false unless uri.fragment.nil?
            return false unless uri.query.nil?
            return false if uri.respond_to?(:user) && (uri.user || uri.password)

            path = uri.path.to_s
            return false if path.empty? || path == "/"

            decoded = path.gsub(/%2[eE]/, ".")
            segments = decoded.split("/", -1)
            return false if segments.any? { |segment| segment == "." || segment == ".." }

            true
          rescue URI::InvalidURIError
            false
          end

          # Infers the OIDC Dynamic Client Registration `application_type` for a client from its `redirect_uris`.
          # Per SEP-837, MCP clients MUST specify an appropriate application type during Dynamic Client Registration
          # so the authorization server can apply the matching redirect URI policy.
          #
          # Returns `"native"` when every redirect URI is a native-app URI: a custom non-http(s) scheme (RFC 8252 Section 7.1)
          # or an http(s) URI whose host is a loopback address (`localhost`, `127.0.0.0/8`, or `::1`, RFC 8252 Section 7.3).
          # Returns `"web"` otherwise, including when `redirect_uris` is nil, empty, or contains an unparseable URI.
          #
          # - https://github.com/modelcontextprotocol/modelcontextprotocol/pull/837
          # - https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
          def infer_application_type(redirect_uris)
            uris = Array(redirect_uris)
            return "web" if uris.empty?

            uris.all? { |uri| native_redirect_uri?(uri) } ? "native" : "web"
          end

          # Like `canonicalize_url` but also strips query string, fragment, and
          # userinfo. This variant is used for identity comparison against
          # the request URL Faraday actually sends, which differs from the value
          # the caller passed in two ways: `Faraday::Connection#url_prefix`
          # drops query parameters, and Faraday hoists `user:pass@` out of
          # the URL into an `Authorization: Basic` header before the request goes
          # out. Including userinfo here would (a) raise a false-positive
          # `InsecureURLError` on any legitimate URL with credentials in
          # the authority, and (b) leak `user:pass` through the resulting error
          # message - both of which would defeat the bearer-token-protection
          # purpose of the identity check.
          def canonicalize_origin_and_path(url)
            uri = URI.parse(url.to_s)

            uri.fragment = nil
            uri.query = nil
            # `URI::Generic#userinfo=` is a no-op on Ruby 2.7 (the project's minimum supported version),
            # so clear the components individually.
            if uri.respond_to?(:user) && (uri.user || uri.password)
              uri.user = nil
              uri.password = nil
            end
            uri.scheme = uri.scheme.downcase if uri.scheme
            uri.host = uri.host.downcase if uri.host
            uri.port = nil if uri.port == uri.default_port

            path = uri.path.to_s.gsub(/%2[eE]/, ".")
            uri.path = remove_dot_segments(path)
            uri.path = "" if uri.path == "/"

            uri.to_s
          end

          # Returns true when `prm` (a PRM `resource` URL) covers `server`
          # (the MCP endpoint URL): same scheme/host/port, with PRM's path being
          # a prefix of the server's path. When PRM also advertises a query
          # string, the server's query MUST be identical to it
          # (otherwise a hijacked PRM that advertises `?tenant=evil` would cover
          # an MCP server at `?tenant=victim` and let the attacker mint
          # a different tenant's token for the same origin + path).
          # PRM with *no* query (URI#query returns `nil`) acts as a generic identifier
          # over the origin + path prefix and covers any server query.
          #
          # An empty query (`prm_url?` -- URI#query returns `""`) is NOT
          # treated as wildcard: it represents the URI literally `<...>?`,
          # which is distinct from "no query at all" and from any non-empty query,
          # so it must match exactly.
          #
          # Both arguments must already be canonicalized.
          def resource_covers?(prm:, server:)
            prm_uri = URI.parse(prm)
            server_uri = URI.parse(server)
            return false unless prm_uri.scheme == server_uri.scheme &&
              prm_uri.host == server_uri.host &&
              prm_uri.port == server_uri.port

            prm_path = prm_uri.path.to_s
            server_path = server_uri.path.to_s
            prm_path = "" if prm_path == "/"
            server_path = "" if server_path == "/"
            path_covers = server_path == prm_path || server_path.start_with?("#{prm_path}/")
            return false unless path_covers

            prm_query = prm_uri.query
            return true if prm_query.nil?

            prm_query == server_uri.query
          end

          private

          # Unescapes a `quoted-string` value's `quoted-pair` octets per
          # RFC 7230 Section 3.2.6 (referenced from RFC 7235): `\<char>` becomes `<char>`.
          # https://www.rfc-editor.org/rfc/rfc7230#section-3.2.6
          def unescape_quoted_pair(value)
            value.gsub(/\\(.)/, '\1')
          end

          # Recognizes the IPv4 loopback range (`127.0.0.0/8`), IPv6 loopback
          # (`::1`, optionally bracketed by `URI.parse`), and the `localhost`
          # hostname (matched exactly so that hostnames like `foo.localhost` or
          # `127.attacker.com` are not treated as loopback).
          IPV4_LOOPBACK_RANGE = IPAddr.new("127.0.0.0/8")
          IPV6_LOOPBACK = IPAddr.new("::1")
          private_constant :IPV4_LOOPBACK_RANGE, :IPV6_LOOPBACK

          def loopback_host?(host)
            return false if host.nil? || host.empty?

            normalized = host.downcase
            return true if normalized == "localhost"

            ip_candidate = normalized.delete_prefix("[").delete_suffix("]")
            address = parse_ip_address(ip_candidate)
            return false unless address

            return IPV4_LOOPBACK_RANGE.include?(address) if address.ipv4?
            return address == IPV6_LOOPBACK if address.ipv6?

            false
          end

          def parse_ip_address(candidate)
            IPAddr.new(candidate)
          rescue IPAddr::Error
            nil
          end

          # A redirect URI counts as native when it uses a custom non-http(s) scheme
          # (e.g. `com.example.app:/callback`) or when it is an http(s) URI whose host is
          # a loopback address. A URI without a scheme or one that fails to parse is not native.
          def native_redirect_uri?(url)
            uri = URI.parse(url.to_s)
            scheme = uri.scheme&.downcase
            return false if scheme.nil?
            return loopback_host?(uri.host) if ["http", "https"].include?(scheme)

            true
          rescue URI::InvalidURIError
            false
          end

          def base_url(uri)
            port_part = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
            "#{uri.scheme}://#{uri.host}#{port_part}"
          end

          # Normalizes a URL query string so two URLs that are equivalent in
          # OAuth identity terms compare as equal. This is required because
          # Faraday transparently rewrites `env.url` before sending a request:
          #
          # - Parameters get sorted by name (`?b=2&a=1` -> `?a=1&b=2`).
          # - Percent-encoded hex is uppercased (`?x=%2f` -> `?x=%2F`).
          # - A trailing `?` with no parameters is dropped (`?` -> no query).
          # - Same-name keys are collapsed so only the last value survives
          #   (`?a=1&a=2` -> `?a=2`).
          # - Empty-name pairs and blank `&&` separators are dropped
          #   (`?=v` -> no query, `?&&a=1&&` -> `?a=1`).
          # - Value-less keys (`?tenant`) and empty-value keys (`?tenant=`)
          #   are kept distinct -- Faraday preserves the `=` exactly as
          #   the caller passed it. `URI.decode_www_form` / `encode_www_form`
          #   would collapse both to `?tenant=`, so this function does
          #   the parsing by hand on `&`-separated segments.
          #
          # Without applying the same transformation to our snapshotted URL,
          # the request-time URL guard would false-positive on every URL that
          # falls under one of the rules above.
          #
          # Returns `nil` when the resulting query is empty
          # (matching Faraday's drop-empty-query behavior).
          def normalize_query(query)
            return if query.nil? || query.empty?

            # Each segment becomes `[decoded_name, has_equals?, decoded_value_or_nil]`.
            # `has_equals?` is what lets us preserve the `?key` vs `?key=`
            # distinction that Faraday respects.
            parsed = query.split("&").filter_map do |segment|
              next if segment.empty?

              name_raw, separator, value_raw = segment.partition("=")
              name = URI.decode_www_form_component(name_raw)
              next if name.empty?

              has_equals = !separator.empty?
              value = has_equals ? URI.decode_www_form_component(value_raw) : nil
              [name, has_equals, value]
            end

            # Keys ending in `[]` (`tenant[]`, `roles[]`) are Faraday's array
            # notation: the encoder preserves every occurrence in input order
            # instead of collapsing them. All other keys (`tenant`, `a[b]`,
            # plain scalars) are collapsed with last-write-wins semantics.
            # Separating the two avoids a false negative where a hijacked
            # middleware drops an entry from a `?tenant[]=victim&tenant[]=...`
            # URL and slips past the guard, and a false positive on
            # a legitimate `?roles[]=a&roles[]=b` URL.
            array_segments = []
            scalar_segments = {}
            parsed.each do |name, has_equals, value|
              if name.end_with?("[]")
                array_segments << [name, has_equals, value]
              else
                scalar_segments[name] = [has_equals, value]
              end
            end

            scalar_entries = scalar_segments.map { |name, (has_equals, value)| [name, has_equals, value] }
            combined = scalar_entries + array_segments
            return if combined.empty?

            # Stable sort by name: array entries that share a name keep their
            # original order, while scalar names are alphabetized to match
            # Faraday's deterministic encoding order.
            combined.each_with_index
              .sort_by { |(name, _, _), index| [name, index] }
              .map do |(name, has_equals, value), _index|
                encoded_name = URI.encode_www_form_component(name)
                if has_equals
                  "#{encoded_name}=#{URI.encode_www_form_component(value)}"
                else
                  encoded_name
                end
              end.join("&")
          end

          # Implements RFC 3986 Section 5.2.4 `remove_dot_segments`. Walks the input
          # buffer one segment at a time, popping the previous output segment
          # whenever a `..` is encountered, so that `/api/../mcp` collapses to
          # `/mcp` and `/foo/./bar` collapses to `/foo/bar`.
          # https://www.rfc-editor.org/rfc/rfc3986#section-5.2.4
          def remove_dot_segments(path)
            return path if path.nil? || path.empty?

            input = path.dup
            output = +""
            until input.empty?
              if input.start_with?("../")
                input = input[3..]
              elsif input.start_with?("./")
                input = input[2..]
              elsif input.start_with?("/./")
                input = "/#{input[3..]}"
              elsif input == "/."
                input = "/"
              elsif input.start_with?("/../")
                input = "/#{input[4..]}"
                output = remove_last_segment(output)
              elsif input == "/.."
                input = "/"
                output = remove_last_segment(output)
              elsif input == "." || input == ".."
                input = ""
              else
                segment = input.match(%r{\A/?[^/]*})[0]
                output << segment
                input = input[segment.length..]
              end
            end
            output
          end

          def remove_last_segment(output)
            idx = output.rindex("/")
            return +"" if idx.nil?

            output[0...idx]
          end
        end
      end
    end
  end
end
