# frozen_string_literal: true

require "test_helper"
require "mcp/client/oauth/discovery"

module MCP
  class Server
    module OAuth
      class ChallengeTest < Minitest::Test
        def test_build_with_all_parameters
          header = Challenge.build(
            error: "invalid_token",
            error_description: "Token expired",
            scope: "mcp:tools mcp:resources",
            resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
          )

          assert_equal(
            'Bearer error="invalid_token", error_description="Token expired", ' \
              'scope="mcp:tools mcp:resources", ' \
              'resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"',
            header,
          )
        end

        def test_build_without_parameters
          assert_equal("Bearer", Challenge.build)
        end

        def test_build_escapes_quotes_and_backslashes
          header = Challenge.build(error_description: 'bad "token" with \\ inside')

          assert_equal('Bearer error_description="bad \\"token\\" with \\\\ inside"', header)
        end

        def test_build_strips_header_injection_characters
          header = Challenge.build(error_description: "line one\r\nSet-Cookie: evil=1")

          refute_includes(header, "\r")
          refute_includes(header, "\n")
        end

        def test_build_strips_other_control_characters
          header = Challenge.build(error_description: "null\x00byte and\ttab")

          assert_equal('Bearer error_description="null byte and tab"', header)
        end

        def test_build_scrubs_invalid_byte_sequences
          header = Challenge.build(error_description: "bad \xFF byte")

          assert_predicate(header, :valid_encoding?)
          assert_equal('Bearer error_description="bad ? byte"', header)
        end

        def test_build_normalizes_binary_strings_to_utf8
          # Rack hands header values over as ASCII-8BIT, where every byte is "valid" and `scrub` is a no-op.
          header = Challenge.build(error_description: "bad \xFF byte".b)

          assert_equal(Encoding::UTF_8, header.encoding)
          assert_predicate(header, :valid_encoding?)
          assert_equal('Bearer error_description="bad ? byte"', header)
        end

        def test_build_round_trips_with_client_discovery_parser
          header = Challenge.build(
            error: "insufficient_scope",
            error_description: 'needs "admin" scope, got \\ none',
            scope: "mcp:tools admin",
            resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource",
          )

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(header)

          assert_equal("insufficient_scope", params["error"])
          assert_equal('needs "admin" scope, got \\ none', params["error_description"])
          assert_equal("mcp:tools admin", params["scope"])
          assert_equal("https://mcp.example.com/.well-known/oauth-protected-resource", params["resource_metadata"])
        end

        def test_invalid_token_response
          status, headers, body = Challenge.invalid_token_response(
            error_description: "Token expired",
            scope: "mcp:tools",
            resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource",
          )

          assert_equal(401, status)
          assert_equal("application/json", headers["content-type"])

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_token", params["error"])
          assert_equal("Token expired", params["error_description"])
          assert_equal("mcp:tools", params["scope"])
          assert_equal("https://mcp.example.com/.well-known/oauth-protected-resource", params["resource_metadata"])

          parsed_body = JSON.parse(body.join)

          assert_equal("invalid_token", parsed_body["error"])
          assert_equal("Token expired", parsed_body["error_description"])
        end

        def test_missing_token_response_carries_no_error_code
          status, headers, body = Challenge.missing_token_response(
            scope: "mcp:tools",
            resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource",
          )

          assert_equal(401, status)
          assert_empty(body)
          refute(headers.key?("content-type"))

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          refute(params.key?("error"))
          assert_equal("mcp:tools", params["scope"])
          assert_equal("https://mcp.example.com/.well-known/oauth-protected-resource", params["resource_metadata"])
        end

        def test_insufficient_scope_response
          status, headers, body = Challenge.insufficient_scope_response(
            error_description: "Requires the admin scope",
            scope: "mcp:tools admin",
            resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource",
          )

          assert_equal(403, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("insufficient_scope", params["error"])
          assert_equal("mcp:tools admin", params["scope"])
          assert_equal("insufficient_scope", JSON.parse(body.join)["error"])
        end

        def test_invalid_request_response
          status, headers, body = Challenge.invalid_request_response(error_description: "Unsupported authorization scheme")

          assert_equal(400, status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(headers["www-authenticate"])

          assert_equal("invalid_request", params["error"])
          assert_equal("invalid_request", JSON.parse(body.join)["error"])
        end

        def test_responses_omit_missing_parameters
          _status, headers, body = Challenge.invalid_token_response

          assert_equal('Bearer error="invalid_token"', headers["www-authenticate"])
          refute(JSON.parse(body.join).key?("error_description"))
        end
      end
    end
  end
end
