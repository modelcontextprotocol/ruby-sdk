# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth/discovery"

module MCP
  class Client
    module OAuth
      class DiscoveryTest < Minitest::Test
        def test_parse_www_authenticate_with_quoted_resource_metadata
          header = 'Bearer error="invalid_token", error_description="Missing", ' \
            'resource_metadata="https://srv.example.com/.well-known/oauth-protected-resource/mcp"'
          params = Discovery.parse_www_authenticate(header)

          assert_equal("invalid_token", params["error"])
          assert_equal("Missing", params["error_description"])
          assert_equal("https://srv.example.com/.well-known/oauth-protected-resource/mcp", params["resource_metadata"])
        end

        def test_parse_www_authenticate_returns_empty_for_other_schemes
          assert_empty(Discovery.parse_www_authenticate('Basic realm="x"'))
        end

        def test_parse_www_authenticate_returns_empty_for_nil
          assert_empty(Discovery.parse_www_authenticate(nil))
        end

        def test_parse_www_authenticate_finds_bearer_after_other_scheme
          header = 'Basic realm="x", Bearer error="invalid_token", resource_metadata="https://srv/x"'
          params = Discovery.parse_www_authenticate(header)

          assert_equal("invalid_token", params["error"])
          assert_equal("https://srv/x", params["resource_metadata"])
        end

        def test_parse_www_authenticate_stops_at_following_scheme
          header = 'Bearer error="invalid_token", resource_metadata="https://srv/x", DPoP algs="ES256"'
          params = Discovery.parse_www_authenticate(header)

          assert_equal("invalid_token", params["error"])
          assert_equal("https://srv/x", params["resource_metadata"])
          refute(params.key?("algs"))
        end

        def test_parse_www_authenticate_returns_empty_when_bearer_absent
          assert_empty(Discovery.parse_www_authenticate('DPoP algs="ES256"'))
        end

        def test_parse_www_authenticate_handles_bare_bearer
          assert_empty(Discovery.parse_www_authenticate("Bearer"))
        end

        def test_parse_www_authenticate_handles_tab_separator
          params = Discovery.parse_www_authenticate(%(Bearer\terror="invalid_token",\tresource_metadata="https://srv/x"))

          assert_equal("invalid_token", params["error"])
          assert_equal("https://srv/x", params["resource_metadata"])
        end

        def test_parse_www_authenticate_tolerates_trailing_comma
          params = Discovery.parse_www_authenticate('Bearer error="invalid_token", resource_metadata="https://srv/x",')

          assert_equal("invalid_token", params["error"])
          assert_equal("https://srv/x", params["resource_metadata"])
        end

        def test_parse_www_authenticate_handles_quoted_value_with_comma_and_spaces
          params = Discovery.parse_www_authenticate('Bearer error_description="missing, expired, or revoked token"')

          assert_equal("missing, expired, or revoked token", params["error_description"])
        end

        def test_parse_www_authenticate_unescapes_quoted_pair
          # Per RFC 7230 Section 3.2.6, a backslash inside a quoted-string escapes
          # the next character. The parser must surface the unescaped form.
          header = 'Bearer error_description="value with \"quoted\" word and a back\\\\slash"'
          params = Discovery.parse_www_authenticate(header)

          assert_equal('value with "quoted" word and a back\\slash', params["error_description"])
        end

        def test_protected_resource_metadata_urls_uses_explicit_url_first
          urls = Discovery.protected_resource_metadata_urls(
            server_url: "https://api.example.com/mcp",
            resource_metadata_url: "https://api.example.com/.well-known/oauth-protected-resource/mcp",
          )

          assert_equal("https://api.example.com/.well-known/oauth-protected-resource/mcp", urls.first)
          assert_includes(urls, "https://api.example.com/.well-known/oauth-protected-resource")
        end

        def test_protected_resource_metadata_urls_falls_back_to_path_then_root
          urls = Discovery.protected_resource_metadata_urls(server_url: "https://api.example.com/mcp")

          assert_equal(
            [
              "https://api.example.com/.well-known/oauth-protected-resource/mcp",
              "https://api.example.com/.well-known/oauth-protected-resource",
            ],
            urls,
          )
        end

        def test_authorization_server_metadata_urls_for_root_issuer
          urls = Discovery.authorization_server_metadata_urls("https://auth.example.com")

          assert_equal(
            [
              "https://auth.example.com/.well-known/oauth-authorization-server",
              "https://auth.example.com/.well-known/openid-configuration",
            ],
            urls,
          )
        end

        def test_authorization_server_metadata_urls_for_path_issuer
          urls = Discovery.authorization_server_metadata_urls("https://auth.example.com/tenant1")

          assert_includes(urls, "https://auth.example.com/.well-known/oauth-authorization-server/tenant1")
          assert_includes(urls, "https://auth.example.com/.well-known/openid-configuration/tenant1")
          assert_includes(urls, "https://auth.example.com/tenant1/.well-known/openid-configuration")
        end

        # Per SEP-2351, MCP explicitly uses the RFC 8414 default `oauth-authorization-server` well-known URI suffix
        # and defines no application-specific suffix. The first probed candidate for a root issuer must be exactly
        # that default suffix.
        def test_authorization_server_metadata_urls_probe_rfc8414_default_suffix_first
          urls = Discovery.authorization_server_metadata_urls("https://auth.example.com")

          assert_equal("https://auth.example.com/.well-known/oauth-authorization-server", urls.first)
        end

        def test_authorization_server_metadata_urls_use_only_registered_well_known_suffixes
          root_urls = Discovery.authorization_server_metadata_urls("https://auth.example.com")
          path_urls = Discovery.authorization_server_metadata_urls("https://auth.example.com/tenant1")

          (root_urls + path_urls).each do |url|
            suffix = url[%r{/\.well-known/([^/]+)}, 1]

            assert_includes(
              ["oauth-authorization-server", "openid-configuration"], suffix, "unexpected well-known suffix in #{url}"
            )
          end
        end

        def test_authorization_server_metadata_urls_put_path_inserted_oauth_candidate_first_for_path_issuer
          urls = Discovery.authorization_server_metadata_urls("https://auth.example.com/tenant1")

          assert_equal("https://auth.example.com/.well-known/oauth-authorization-server/tenant1", urls.first)
        end

        def test_authorization_server_metadata_urls_treat_trailing_slash_issuer_as_root
          urls = Discovery.authorization_server_metadata_urls("https://auth.example.com/")

          assert_equal(
            ["https://auth.example.com/.well-known/oauth-authorization-server", "https://auth.example.com/.well-known/openid-configuration"],
            urls,
          )
        end

        def test_infer_application_type_returns_native_for_loopback_http_redirect_uris
          uris = ["http://localhost:0/callback", "http://127.0.0.1:8080/cb", "http://[::1]/cb"]

          assert_equal("native", Discovery.infer_application_type(uris))
        end

        def test_infer_application_type_returns_native_for_custom_scheme_redirect_uris
          assert_equal("native", Discovery.infer_application_type(["com.example.app:/oauth/callback"]))
        end

        def test_infer_application_type_returns_web_for_https_redirect_uris
          assert_equal("web", Discovery.infer_application_type(["https://app.example.com/callback"]))
        end

        def test_infer_application_type_returns_web_when_any_redirect_uri_is_not_native
          uris = ["http://localhost:0/callback", "https://app.example.com/callback"]

          assert_equal("web", Discovery.infer_application_type(uris))
        end

        def test_infer_application_type_returns_web_for_localhost_lookalike_host
          assert_equal("web", Discovery.infer_application_type(["http://localhost.example.com/cb"]))
        end

        def test_infer_application_type_returns_web_for_nil_or_empty_redirect_uris
          assert_equal("web", Discovery.infer_application_type(nil))
          assert_equal("web", Discovery.infer_application_type([]))
        end

        def test_infer_application_type_returns_web_for_unparseable_redirect_uri
          assert_equal("web", Discovery.infer_application_type(["http://[invalid"]))
        end

        def test_canonicalize_url_normalizes_scheme_host_port_and_path
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("HTTPS://Srv.Example.COM:443/mcp#frag"),
          )
          assert_equal(
            "http://srv.example.com",
            Discovery.canonicalize_url("http://Srv.Example.COM:80/"),
          )
          assert_equal(
            "https://srv.example.com:8443/mcp",
            Discovery.canonicalize_url("https://srv.example.com:8443/mcp"),
          )
        end

        def test_canonicalize_url_resolves_dot_segments
          # Critical for audience binding: an attacker-supplied URL like
          # `/api/../mcp` must collapse to `/mcp` so it cannot pass a PRM check
          # whose `resource` is the more privileged `/api` path.
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/api/../mcp"),
          )
          assert_equal(
            "https://srv.example.com/api/mcp",
            Discovery.canonicalize_url("https://srv.example.com/api/./mcp"),
          )
          assert_equal(
            "https://srv.example.com/bar",
            Discovery.canonicalize_url("https://srv.example.com/foo/../../bar"),
          )
          assert_equal(
            "https://srv.example.com",
            Discovery.canonicalize_url("https://srv.example.com/api/.."),
          )
        end

        def test_canonicalize_url_resolves_percent_encoded_dot_segments
          # `%2e` and `%2E` are percent-encoded forms of `.` (RFC 3986 Section 6.2.2.2)
          # and must be decoded *before* dot-segment resolution. Otherwise,
          # an attacker-supplied URL like `/api/%2e%2e/mcp` would slip past
          # `remove_dot_segments` and escape the PRM `resource=/api` audience
          # binding.
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/api/%2e%2e/mcp"),
          )
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/api/%2E%2E/mcp"),
          )
          assert_equal(
            "https://srv.example.com/api/mcp",
            Discovery.canonicalize_url("https://srv.example.com/api/%2e/mcp"),
          )
        end

        def test_canonicalize_url_drops_userinfo
          # The canonicalized URL is sent on the wire as the RFC 8707 `resource`
          # claim and is surfaced in error messages, so credentials in
          # the authority must never round-trip: dropping `user:pass@` keeps them
          # from leaking to the authorization server or to log destinations.
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://user:pass@Srv.Example.COM:443/api/../mcp"),
          )
        end

        def test_canonicalize_url_normalizes_query_to_match_faraday
          # Faraday rewrites `env.url` before sending a request: it sorts
          # parameters by name, uppercases percent-encoded hex, and drops
          # a bare `?` with no parameters. The canonical form must apply
          # the same transformation so the URL guard does not raise a false
          # positive on every valid request with a query string.
          assert_equal(
            "https://srv.example.com/mcp?a=1&b=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?b=2&a=1"),
          )
          assert_equal(
            "https://srv.example.com/mcp?x=%2F",
            Discovery.canonicalize_url("https://srv.example.com/mcp?x=%2f"),
          )
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/mcp?"),
          )
        end

        def test_canonicalize_url_collapses_same_name_query_parameters
          # Faraday's internal query encoder uses a Hash, so repeated keys
          # collapse to the last value. The canonical form must apply
          # the same collapse, otherwise the URL guard false-positives on URLs
          # like `?a=1&a=2` (Faraday rewrites to `?a=2`).
          assert_equal(
            "https://srv.example.com/mcp?a=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a=1&a=2"),
          )
          assert_equal(
            "https://srv.example.com/mcp?a=3&b=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a=1&b=2&a=3"),
          )
          assert_equal(
            "https://srv.example.com/mcp?x=%2F",
            Discovery.canonicalize_url("https://srv.example.com/mcp?x=%2f&x=%2F"),
          )
        end

        def test_canonicalize_url_preserves_valueless_vs_empty_value_distinction
          # Faraday preserves the difference between `?key` (no `=`) and
          # `?key=` (empty value) exactly as the caller passed it. A naive
          # `URI.decode_www_form` round-trip would collapse both to `?key=`
          # and false-positive the URL guard / RFC 8707 `resource` check for
          # any URL that uses the value-less form.
          assert_equal(
            "https://srv.example.com/mcp?tenant",
            Discovery.canonicalize_url("https://srv.example.com/mcp?tenant"),
          )
          assert_equal(
            "https://srv.example.com/mcp?tenant=",
            Discovery.canonicalize_url("https://srv.example.com/mcp?tenant="),
          )
          assert_equal(
            "https://srv.example.com/mcp?a=1&b",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a=1&b"),
          )
          # Collapse with last-write-wins also keeps the `=` form of
          # the surviving segment: `flag=1&flag` -> last is `flag` (no `=`), so
          # the canonical form is `?flag`, matching Faraday.
          assert_equal(
            "https://srv.example.com/mcp?flag",
            Discovery.canonicalize_url("https://srv.example.com/mcp?flag=1&flag"),
          )
        end

        def test_canonicalize_url_preserves_array_form_repeated_keys
          # Keys ending in `[]` are Faraday's array notation: the encoder
          # preserves every occurrence in input order instead of collapsing
          # them. The canonical form must do the same; otherwise a hijacked
          # middleware that drops one entry from `?tenant[]=victim&tenant[]=...`
          # would slip past the URL guard, and a legitimate
          # `?roles[]=a&roles[]=b` URL would false-positive on the first
          # request.
          assert_equal(
            "https://srv.example.com/mcp?a%5B%5D=1&a%5B%5D=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a[]=1&a[]=2"),
          )
          assert_equal(
            "https://srv.example.com/mcp?tenant%5B%5D=evil&tenant%5B%5D=victim",
            Discovery.canonicalize_url("https://srv.example.com/mcp?tenant[]=evil&tenant[]=victim"),
          )
          assert_equal(
            "https://srv.example.com/mcp?a%5B%5D=1&a%5B%5D=2&b=3",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a[]=1&a[]=2&b=3"),
          )
          # Nested keys like `a[b]` are not array notation. They collapse with
          # last-write-wins, matching Faraday's `NestedParamsEncoder`.
          assert_equal(
            "https://srv.example.com/mcp?a%5Bb%5D=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a[b]=1&a[b]=2"),
          )
        end

        def test_canonicalize_url_drops_empty_name_and_blank_query_segments
          # Faraday's encoder treats pairs with an empty name and blank `&&`
          # separators as no parameter at all. The canonical form must do
          # the same; otherwise URLs like `?=v` or `?&&a=1&&` produce a snapshot
          # that disagrees with the Faraday-rewritten effective URL and
          # the request-time guard false-positives.
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/mcp?=v"),
          )
          assert_equal(
            "https://srv.example.com/mcp?a=1",
            Discovery.canonicalize_url("https://srv.example.com/mcp?&&a=1&&"),
          )
          assert_equal(
            "https://srv.example.com/mcp?a=2",
            Discovery.canonicalize_url("https://srv.example.com/mcp?a=1&&a=2"),
          )
          assert_equal(
            "https://srv.example.com/mcp?a=1",
            Discovery.canonicalize_url("https://srv.example.com/mcp?=&=&a=1"),
          )
          assert_equal(
            "https://srv.example.com/mcp",
            Discovery.canonicalize_url("https://srv.example.com/mcp?&"),
          )
        end

        def test_resource_covers_blocks_dot_segment_bypass_after_canonicalization
          server = Discovery.canonicalize_url("https://srv.example.com/api/../mcp")
          prm = Discovery.canonicalize_url("https://srv.example.com/api")

          refute(
            Discovery.resource_covers?(prm: prm, server: server),
            "PRM `resource=/api` must not cover `/api/../mcp` after canonicalization",
          )
        end

        def test_secure_url_accepts_https
          assert(Discovery.secure_url?("https://srv.example.com/mcp"))
          assert(Discovery.secure_url?("HTTPS://Srv.Example.COM/mcp"))
        end

        def test_secure_url_accepts_loopback_http
          assert(Discovery.secure_url?("http://localhost/x"))
          assert(Discovery.secure_url?("http://localhost:8080/x"))
          assert(Discovery.secure_url?("http://127.0.0.1/x"))
          assert(Discovery.secure_url?("http://127.42.0.5/x"))
          assert(Discovery.secure_url?("http://127.255.255.255/x"))
          assert(Discovery.secure_url?("http://[::1]/x"))
        end

        def test_secure_url_rejects_non_loopback_http
          refute(Discovery.secure_url?("http://srv.example.com/mcp"))
          refute(Discovery.secure_url?("http://192.168.1.1/x"))
          refute(Discovery.secure_url?("http://10.0.0.1/x"))
        end

        def test_secure_url_rejects_hostname_tricks_that_resemble_loopback
          # Naive `start_with?("127.")` would let these slip through; IPAddr-based
          # checks correctly classify them as non-loopback hostnames.
          refute(Discovery.secure_url?("http://127.attacker.com/x"))
          refute(Discovery.secure_url?("http://127.0.0.1.evil.com/x"))
          refute(Discovery.secure_url?("http://127./x"))
          # `localhost` MUST be matched exactly - `foo.localhost` is just a regular
          # hostname that happens to share the suffix.
          refute(Discovery.secure_url?("http://foo.localhost/x"))
        end

        def test_secure_url_rejects_non_http_schemes
          refute(Discovery.secure_url?("ftp://srv.example.com/mcp"))
          refute(Discovery.secure_url?("file:///etc/passwd"))
          refute(Discovery.secure_url?("javascript:alert(1)"))
          refute(Discovery.secure_url?(""))
          refute(Discovery.secure_url?(nil))
        end

        def test_secure_url_rejects_malformed_or_hostless_urls
          refute(Discovery.secure_url?("https:/missing-host"))
          refute(Discovery.secure_url?("https:///missing-host"))
          refute(Discovery.secure_url?("https://"))
          refute(Discovery.secure_url?("not a url"))
        end

        def test_client_id_metadata_document_url_accepts_https_with_path
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com/client-metadata.json"))
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com/path/to/cm"))
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com:8443/cm"))
        end

        def test_client_id_metadata_document_url_accepts_boundary_forms
          # An uppercase scheme is `https` after case folding (URIs are scheme-insensitive, RFC 3986 Section 3.1).
          assert(Discovery.client_id_metadata_document_url?("HTTPS://app.example.com/cm"))

          # A trailing slash and consecutive slashes are non-root, non-dot paths.
          # RFC 3986 `remove_dot_segments` does not collapse them, so they remain
          # stable `client_id` strings rather than aliasing another URL.
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com/cm/"))
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com//cm"))

          # The default https port is equivalent to omitting it; either form is a valid origin.
          assert(Discovery.client_id_metadata_document_url?("https://app.example.com:443/cm"))

          # IPv6 literal hosts and Punycode (IDN) hosts are ordinary hosts.
          assert(Discovery.client_id_metadata_document_url?("https://[2001:db8::1]/cm"))
          assert(Discovery.client_id_metadata_document_url?("https://[::1]/cm"))
          assert(Discovery.client_id_metadata_document_url?("https://xn--e1afmkfd.example.com/cm"))
        end

        def test_client_id_metadata_document_url_rejects_non_https_schemes
          refute(Discovery.client_id_metadata_document_url?("http://localhost/cm"))
          refute(Discovery.client_id_metadata_document_url?("http://app.example.com/cm"))
          refute(Discovery.client_id_metadata_document_url?("ftp://app.example.com/cm"))
          refute(Discovery.client_id_metadata_document_url?("file:///cm"))
        end

        def test_client_id_metadata_document_url_rejects_root_and_empty_path
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com"))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/"))
        end

        def test_client_id_metadata_document_url_rejects_fragment_query_userinfo
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/cm#frag"))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/cm?x=1"))
          refute(Discovery.client_id_metadata_document_url?("https://user:pass@app.example.com/cm"))
          refute(Discovery.client_id_metadata_document_url?("https://user@app.example.com/cm"))
        end

        def test_client_id_metadata_document_url_rejects_dot_segments
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/./cm"))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/a/../cm"))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/cm/."))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/cm/.."))
          # Percent-encoded `.` would otherwise let `%2E` and `.` produce
          # different `client_id` values for the same document.
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/%2E/cm"))
          refute(Discovery.client_id_metadata_document_url?("https://app.example.com/%2e/cm"))
        end

        def test_client_id_metadata_document_url_rejects_nil_or_empty_or_malformed
          refute(Discovery.client_id_metadata_document_url?(nil))
          refute(Discovery.client_id_metadata_document_url?(""))
          refute(Discovery.client_id_metadata_document_url?("not a url"))
          refute(Discovery.client_id_metadata_document_url?("https://"))
        end

        def test_resource_covers_blocks_percent_encoded_dot_segment_bypass
          server = Discovery.canonicalize_url("https://srv.example.com/api/%2e%2e/mcp")
          prm = Discovery.canonicalize_url("https://srv.example.com/api")

          refute(
            Discovery.resource_covers?(prm: prm, server: server),
            "PRM `resource=/api` must not cover `/api/%2e%2e/mcp` after canonicalization",
          )
        end

        def test_resource_covers_blocks_cross_tenant_query_bypass
          # An attacker-controlled PRM that advertises a different tenant's
          # resource URI MUST NOT be treated as covering the server URL. If it
          # were, the client would mint a token for `tenant=evil` while
          # actually talking to `tenant=victim`, defeating audience binding.
          server = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=victim")
          prm_evil = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=evil")

          refute(
            Discovery.resource_covers?(prm: prm_evil, server: server),
            "PRM `resource=?tenant=evil` must not cover server `?tenant=victim`",
          )
        end

        def test_resource_covers_allows_matching_query
          server = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=victim")
          prm = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=victim")

          assert(Discovery.resource_covers?(prm: prm, server: server))
        end

        def test_resource_covers_allows_prm_without_query_to_cover_server_with_query
          # A query-less PRM acts as a generic identifier over the origin +
          # path prefix and is allowed to cover server URLs that scope by query.
          server = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=1")
          prm = Discovery.canonicalize_url("https://srv.example.com/mcp")

          assert(Discovery.resource_covers?(prm: prm, server: server))
        end

        def test_resource_covers_blocks_prm_with_query_when_server_has_none
          # PRM that names a specific tenant cannot cover an unscoped server
          # URL; otherwise a hijacked PRM could re-bind the token to a tenant
          # the user did not select.
          server = Discovery.canonicalize_url("https://srv.example.com/mcp")
          prm = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=evil")

          refute(Discovery.resource_covers?(prm: prm, server: server))
        end

        def test_resource_covers_does_not_treat_empty_query_as_wildcard
          # `https://srv.example.com/mcp?` parses with `URI#query == ""`, which
          # is distinct from "no query at all" (`URI#query == nil`). A naive
          # `prm_query.nil? || prm_query.empty?` would let an attacker-supplied
          # PRM with a trailing `?` slip past the cross-tenant audience check.
          server = Discovery.canonicalize_url("https://srv.example.com/mcp?tenant=victim")
          prm_empty_query = "https://srv.example.com/mcp?"

          refute(
            Discovery.resource_covers?(prm: prm_empty_query, server: server),
            "PRM with a literal empty query (`?`) must not act as a wildcard cover",
          )
        end

        def test_resource_covers_returns_true_for_same_origin_prefix
          assert(Discovery.resource_covers?(
            prm: "https://srv.example.com",
            server: "https://srv.example.com/mcp",
          ))
          assert(Discovery.resource_covers?(
            prm: "https://srv.example.com/mcp",
            server: "https://srv.example.com/mcp",
          ))
          assert(Discovery.resource_covers?(
            prm: "https://srv.example.com/api",
            server: "https://srv.example.com/api/v2/mcp",
          ))
        end

        def test_resource_covers_returns_false_for_different_origin_or_path_mismatch
          refute(Discovery.resource_covers?(
            prm: "https://evil.example.com/mcp",
            server: "https://srv.example.com/mcp",
          ))
          refute(Discovery.resource_covers?(
            prm: "https://srv.example.com:8443/mcp",
            server: "https://srv.example.com/mcp",
          ))
          # Path "api" must not be considered a prefix of "/apiv2".
          refute(Discovery.resource_covers?(
            prm: "https://srv.example.com/api",
            server: "https://srv.example.com/apiv2",
          ))
        end
      end
    end
  end
end
