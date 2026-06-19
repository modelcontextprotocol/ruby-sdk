# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class ProviderTest < Minitest::Test
        # Builds a complete Provider argument hash whose `client_metadata`
        # registers the same `redirect_uri` that is being asserted on.
        # The registered-URI check in `Provider#initialize` requires the two to
        # match, so accept-path tests need them paired.
        def args_for(redirect_uri)
          {
            client_metadata: {
              redirect_uris: [redirect_uri],
              grant_types: ["authorization_code"],
              response_types: ["code"],
              token_endpoint_auth_method: "none",
            },
            redirect_uri: redirect_uri,
            redirect_handler: ->(_url) {},
            callback_handler: -> { ["code", "state"] },
          }
        end

        def test_initialize_accepts_https_redirect_uri
          provider = Provider.new(**args_for("https://app.example.com/callback"))

          assert_equal("https://app.example.com/callback", provider.redirect_uri)
        end

        def test_initialize_accepts_loopback_http_redirect_uri
          ["http://localhost/callback", "http://127.0.0.1:3000/cb", "http://[::1]/cb"].each do |uri|
            provider = Provider.new(**args_for(uri))
            assert_equal(uri, provider.redirect_uri)
          end
        end

        def test_initialize_rejects_non_loopback_http_redirect_uri
          # Communication Security: a non-loopback `http://` redirect URI would
          # let an attacker steal the authorization code from a network sniffer,
          # so the provider must refuse to construct.
          assert_raises(Provider::InsecureRedirectURIError) do
            Provider.new(**args_for("http://app.example.com/callback"))
          end
        end

        def test_initialize_rejects_non_http_scheme_redirect_uri
          assert_raises(Provider::InsecureRedirectURIError) do
            Provider.new(**args_for("ftp://app.example.com/callback"))
          end
        end

        def test_initialize_rejects_hostname_tricks_that_resemble_loopback
          ["http://127.attacker.com/cb", "http://127.0.0.1.evil.com/cb", "http://foo.localhost/cb"].each do |uri|
            assert_raises(Provider::InsecureRedirectURIError, "should reject #{uri}") do
              Provider.new(**args_for(uri))
            end
          end
        end

        def test_initialize_rejects_redirect_uri_not_listed_in_client_metadata
          # Per the OAuth Dynamic Client Registration response, the AS will
          # bind the client_id to a specific set of redirect_uris and reject any
          # authorization request that uses something else. Detect that mismatch
          # at Provider construction so the failure surfaces immediately.
          args = args_for("http://localhost:0/callback")
          args[:redirect_uri] = "http://localhost:0/different"

          assert_raises(Provider::UnregisteredRedirectURIError) do
            Provider.new(**args)
          end
        end

        def test_initialize_accepts_redirect_uri_with_string_keys_in_client_metadata
          # `client_metadata` is hand-built by callers, so accept either symbol
          # or string keys for `redirect_uris`.
          args = args_for("http://localhost:0/callback")
          args[:client_metadata] = { "redirect_uris" => ["http://localhost:0/callback"] }

          provider = Provider.new(**args)
          assert_equal("http://localhost:0/callback", provider.redirect_uri)
        end

        def test_initialize_defaults_client_id_metadata_document_url_to_nil
          provider = Provider.new(**args_for("http://localhost:0/callback"))

          assert_nil(provider.client_id_metadata_document_url)
        end

        def test_initialize_accepts_https_client_id_metadata_document_url
          args = args_for("http://localhost:0/callback").merge(
            client_id_metadata_document_url: "https://app.example.com/client-metadata.json",
          )

          provider = Provider.new(**args)
          assert_equal(
            "https://app.example.com/client-metadata.json",
            provider.client_id_metadata_document_url,
          )
        end

        def test_initialize_rejects_http_client_id_metadata_document_url
          # The loopback `http` carve-out used for discovery does not extend to the CIMD URL:
          # the URL is sent to the AS as the OAuth `client_id` and travels off-loopback,
          # so MCP requires `https`.
          ["http://localhost:8080/client-metadata.json", "http://app.example.com/cm"].each do |uri|
            args = args_for("http://localhost:0/callback").merge(client_id_metadata_document_url: uri)
            assert_raises(Provider::InvalidClientIDMetadataDocumentURLError, "should reject #{uri}") do
              Provider.new(**args)
            end
          end
        end

        def test_initialize_rejects_non_https_scheme_client_id_metadata_document_url
          ["ftp://app.example.com/cm", "file:///cm", "foo://bar/cm"].each do |uri|
            args = args_for("http://localhost:0/callback").merge(client_id_metadata_document_url: uri)
            assert_raises(Provider::InvalidClientIDMetadataDocumentURLError, "should reject #{uri}") do
              Provider.new(**args)
            end
          end
        end

        def test_initialize_rejects_client_id_metadata_document_url_without_path
          # The CIMD document is a discrete resource, not the origin.
          # A bare origin or root-path URL would let two different deployments at
          # the same origin shadow each other under one `client_id`.
          ["https://app.example.com", "https://app.example.com/"].each do |uri|
            args = args_for("http://localhost:0/callback").merge(client_id_metadata_document_url: uri)
            assert_raises(Provider::InvalidClientIDMetadataDocumentURLError, "should reject #{uri}") do
              Provider.new(**args)
            end
          end
        end

        def test_initialize_rejects_client_id_metadata_document_url_with_fragment
          # A fragment is never sent to the server; embedding one in the `client_id` value
          # would make the OAuth `client_id` and the URL the AS dereferences point at different artifacts.
          args = args_for("http://localhost:0/callback").merge(
            client_id_metadata_document_url: "https://app.example.com/cm#frag",
          )
          assert_raises(Provider::InvalidClientIDMetadataDocumentURLError) do
            Provider.new(**args)
          end
        end

        def test_initialize_rejects_client_id_metadata_document_url_with_query
          args = args_for("http://localhost:0/callback").merge(
            client_id_metadata_document_url: "https://app.example.com/cm?x=1",
          )
          assert_raises(Provider::InvalidClientIDMetadataDocumentURLError) do
            Provider.new(**args)
          end
        end

        def test_initialize_rejects_client_id_metadata_document_url_with_userinfo
          # Embedding credentials in the `client_id` leaks them to every AS
          # log line and to the conformance audit trail.
          args = args_for("http://localhost:0/callback").merge(
            client_id_metadata_document_url: "https://user:pass@app.example.com/cm",
          )
          assert_raises(Provider::InvalidClientIDMetadataDocumentURLError) do
            Provider.new(**args)
          end
        end

        def test_initialize_rejects_client_id_metadata_document_url_with_dot_segments
          # `https://x/a/./b` and `https://x/a/b` are RFC 3986 equivalent,
          # so accepting both would let one client publish under two `client_id` values.
          # Reject `.`/`..` (including percent-encoded `.`).
          [
            "https://app.example.com/./cm",
            "https://app.example.com/a/../cm",
            "https://app.example.com/%2E/cm",
          ].each do |uri|
            args = args_for("http://localhost:0/callback").merge(client_id_metadata_document_url: uri)
            assert_raises(Provider::InvalidClientIDMetadataDocumentURLError, "should reject #{uri}") do
              Provider.new(**args)
            end
          end
        end

        def test_authorization_flow_is_authorization_code
          provider = Provider.new(**args_for("https://app.example.com/callback"))

          assert_equal(:authorization_code, provider.authorization_flow)
        end
      end
    end
  end
end
