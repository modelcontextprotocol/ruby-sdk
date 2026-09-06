# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module OAuth
      class ProtectedResourceMetadataTest < Minitest::Test
        def test_requires_absolute_http_resource
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "not a url", authorization_servers: ["https://as.example.com"])
          end
          assert_includes(error.message, "resource must be")

          assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "/mcp", authorization_servers: ["https://as.example.com"])
          end
        end

        def test_rejects_resource_with_fragment
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "https://mcp.example.com/mcp#frag", authorization_servers: ["https://as.example.com"])
          end

          assert_includes(error.message, "fragment")
        end

        def test_requires_at_least_one_authorization_server
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "https://mcp.example.com", authorization_servers: [])
          end

          assert_equal("authorization_servers must contain at least one issuer URL", error.message)
        end

        def test_rejects_non_loopback_http_resource
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "http://mcp.example.com/mcp", authorization_servers: ["https://as.example.com"])
          end

          assert_includes(error.message, "resource must use https")
        end

        def test_rejects_non_loopback_http_authorization_server
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(resource: "https://mcp.example.com/mcp", authorization_servers: ["http://as.example.com"])
          end

          assert_includes(error.message, "authorization_servers must use https")
        end

        def test_extra_fields_are_merged_into_the_document
          metadata = ProtectedResourceMetadata.new(
            resource: "https://mcp.example.com/mcp",
            authorization_servers: ["https://as.example.com"],
            extra: { jwks_uri: "https://mcp.example.com/jwks.json" },
          )

          assert_equal("https://mcp.example.com/jwks.json", metadata.to_h[:jwks_uri])
          assert_equal("https://mcp.example.com/jwks.json", JSON.parse(metadata.to_json)["jwks_uri"])
        end

        def test_extra_cannot_override_the_validated_members
          members = ["resource", "authorization_servers", "scopes_supported", "resource_name", "resource_documentation", "bearer_methods_supported"]

          members.flat_map { |member| [{ member => "overridden" }, { member.to_sym => "overridden" }] }.each do |extra|
            error = assert_raises(ArgumentError) do
              ProtectedResourceMetadata.new(resource: "https://mcp.example.com/mcp", authorization_servers: ["https://as.example.com"], extra: extra)
            end

            assert_includes(error.message, "extra must not override #{extra.keys.first}")
          end
        end

        def test_accepts_a_single_authorization_server_string
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com", authorization_servers: "https://as.example.com")

          assert_equal(["https://as.example.com"], metadata.authorization_servers)
        end

        def test_to_h_uses_spec_field_names_and_compacts
          metadata = ProtectedResourceMetadata.new(
            resource: "https://mcp.example.com/mcp",
            authorization_servers: ["https://as.example.com"],
            scopes_supported: ["mcp:tools"],
            resource_name: "Example MCP Server",
            resource_documentation: "https://mcp.example.com/docs",
          )

          assert_equal(
            {
              resource: "https://mcp.example.com/mcp",
              authorization_servers: ["https://as.example.com"],
              scopes_supported: ["mcp:tools"],
              resource_name: "Example MCP Server",
              resource_documentation: "https://mcp.example.com/docs",
              bearer_methods_supported: ["header"],
            },
            metadata.to_h,
          )

          minimal = ProtectedResourceMetadata.new(resource: "https://mcp.example.com", authorization_servers: ["https://as.example.com"])

          refute(minimal.to_h.key?(:scopes_supported))
          refute(minimal.to_h.key?(:resource_name))
        end

        def test_does_not_advertise_offline_access
          metadata = ProtectedResourceMetadata.new(
            resource: "https://mcp.example.com/mcp",
            authorization_servers: ["https://as.example.com"],
            scopes_supported: ["mcp:tools", "offline_access", "mcp:resources"],
          )

          # The specification tells protected resources not to advertise it, and the challenge builder already drops it,
          # so the document must not disagree with the `scope` parameter the challenges carry.
          assert_equal(["mcp:tools", "mcp:resources"], metadata.scopes_supported)
          assert_equal(["mcp:tools", "mcp:resources"], metadata.to_h[:scopes_supported])
        end

        def test_omits_scopes_supported_when_nothing_is_left_to_advertise
          [["offline_access"], []].each do |scopes_supported|
            metadata = ProtectedResourceMetadata.new(
              resource: "https://mcp.example.com/mcp",
              authorization_servers: ["https://as.example.com"],
              scopes_supported: scopes_supported,
            )

            # RFC 9728 has servers omit an empty member rather than advertise a resource with no scopes at all.
            assert_nil(metadata.scopes_supported)
            refute(metadata.to_h.key?(:scopes_supported))
          end
        end

        def test_requires_scopes_supported_to_be_an_array
          error = assert_raises(ArgumentError) do
            ProtectedResourceMetadata.new(
              resource: "https://mcp.example.com/mcp",
              authorization_servers: ["https://as.example.com"],
              scopes_supported: "mcp:tools mcp:resources",
            )
          end

          assert_includes(error.message, "scopes_supported must be an Array")
        end

        def test_to_json
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com", authorization_servers: ["https://as.example.com"])

          parsed = JSON.parse(metadata.to_json)

          assert_equal("https://mcp.example.com", parsed["resource"])
          assert_equal(["https://as.example.com"], parsed["authorization_servers"])
          assert_equal(["header"], parsed["bearer_methods_supported"])
        end

        def test_well_known_path_for_root_resource
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com", authorization_servers: ["https://as.example.com"])

          assert_equal("/.well-known/oauth-protected-resource", metadata.well_known_path)
        end

        def test_well_known_path_treats_root_slash_as_empty
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com/", authorization_servers: ["https://as.example.com"])

          assert_equal("/.well-known/oauth-protected-resource", metadata.well_known_path)
        end

        def test_well_known_path_inserts_resource_path
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com/mcp", authorization_servers: ["https://as.example.com"])

          assert_equal("/.well-known/oauth-protected-resource/mcp", metadata.well_known_path)
        end

        def test_well_known_url_includes_non_default_port
          metadata = ProtectedResourceMetadata.new(resource: "http://localhost:9393/mcp", authorization_servers: ["http://localhost:9000"])

          assert_equal("http://localhost:9393/.well-known/oauth-protected-resource/mcp", metadata.well_known_url)
        end

        def test_well_known_url_omits_default_port
          metadata = ProtectedResourceMetadata.new(resource: "https://mcp.example.com:443/mcp", authorization_servers: ["https://as.example.com"])

          assert_equal("https://mcp.example.com/.well-known/oauth-protected-resource/mcp", metadata.well_known_url)
        end

        def test_well_known_url_matches_client_discovery_candidates
          [
            "https://mcp.example.com",
            "https://mcp.example.com/",
            "https://mcp.example.com/mcp",
            "http://localhost:9393/nested/mcp",
          ].each do |resource|
            metadata = ProtectedResourceMetadata.new(
              resource: resource,
              authorization_servers: ["https://as.example.com"],
            )

            candidates = MCP::Client::OAuth::Discovery.protected_resource_metadata_urls(server_url: resource)

            assert_includes(candidates, metadata.well_known_url, "for resource #{resource}")
          end
        end
      end
    end
  end
end
