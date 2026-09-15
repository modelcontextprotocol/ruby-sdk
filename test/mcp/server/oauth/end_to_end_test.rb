# frozen_string_literal: true

require "test_helper"
require "json"
require "jwt"
require "rack"
require "webmock/minitest"
require "faraday"
require "mcp/client/http"
require "mcp/client/oauth"

module MCP
  class Server
    module OAuth
      # End-to-end coverage of the resource-server role using the SDK's own
      # OAuth client: the real `MCP::Client::HTTP` + client_credentials provider
      # talks to a real Rack stack (Protected Resource Metadata app + bearer
      # Middleware + StreamableHTTPTransport) routed through WebMock. Only
      # the authorization server is stubbed.
      #
      # Flow under test: 401 challenge -> PRM discovery -> AS metadata discovery
      # -> token grant -> authenticated initialize + tools/call, with the tool
      # observing the verified token via `server_context.auth_info`.
      class EndToEndTest < Minitest::Test
        MCP_URL = "https://mcp.example.com/mcp"
        ISSUER = "https://as.example.com"
        SIGNING_SECRET = "end-to-end-test-secret"

        class WhoamiTool < Tool
          tool_name "whoami"
          description "Reports the authenticated subject"

          class << self
            def call(server_context:)
              observations << server_context.auth_info
              Tool::Response.new([{ type: "text", text: server_context.auth_info.subject.to_s }])
            end

            def observations
              @observations ||= []
            end
          end
        end

        def setup
          WhoamiTool.observations.clear

          @server = MCP::Server.new(name: "e2e_server", tools: [WhoamiTool])
          @transport = Transports::StreamableHTTPTransport.new(@server, enable_json_response: true)

          @metadata = ProtectedResourceMetadata.new(
            resource: MCP_URL,
            authorization_servers: [ISSUER],
            scopes_supported: ["mcp:tools"],
          )

          verifier = JWTVerifier.new(
            resource_metadata: @metadata,
            key: SIGNING_SECRET,
            algorithms: ["HS256"],
          )

          metadata = @metadata
          transport = @transport
          rack_app = Rack::Builder.new do
            use(ProtectedResourceMetadataMiddleware, metadata)

            map("/mcp") do
              use(Middleware, token_verifier: verifier, required_scopes: ["mcp:tools"], resource_metadata: metadata)
              run(transport)
            end
          end

          stub_request(:any, %r{\Ahttps://mcp\.example\.com/}).to_rack(rack_app)
          stub_authorization_server
        end

        def teardown
          @transport.close
          WebMock.reset!
        end

        def test_client_discovers_metadata_obtains_token_and_calls_tool
          oauth = MCP::Client::OAuth::ClientCredentialsProvider.new(
            client_id: "service-client",
            client_secret: "service-secret",
          )
          client = MCP::Client.new(transport: MCP::Client::HTTP.new(url: MCP_URL, oauth: oauth))
          client.connect

          tools = client.tools

          assert_equal(["whoami"], tools.map(&:name))

          response = client.call_tool(tool: tools.first, arguments: {})

          assert_equal("service-account", response.dig("result", "content", 0, "text"))

          # The verified token reached the tool with the claims the AS issued.
          access_token = WhoamiTool.observations.fetch(0)

          assert_equal("service-account", access_token.subject)
          assert_equal("service-client", access_token.client_id)
          assert_equal(["mcp:tools"], access_token.scopes)
          assert_equal(ISSUER, access_token.issuer)
          assert_equal(MCP_URL, access_token.audience)

          # The client discovered the PRM document and requested a token.
          assert_requested(:get, "https://mcp.example.com#{@metadata.well_known_path}")
          assert_requested(:post, "#{ISSUER}/token")
        end

        def test_unauthenticated_request_receives_spec_shaped_challenge
          response = Faraday.post(MCP_URL) do |request|
            request.headers["Content-Type"] = "application/json"
            request.headers["Accept"] = "application/json, text/event-stream"
            request.body = JSON.generate(jsonrpc: "2.0", id: 1, method: "initialize", params: {})
          end

          assert_equal(401, response.status)

          params = MCP::Client::OAuth::Discovery.parse_www_authenticate(response.headers["WWW-Authenticate"])

          # RFC 6750 Section 3.1: no error code when the request carried no credentials.
          refute(params.key?("error"))
          assert_equal("https://mcp.example.com#{@metadata.well_known_path}", params["resource_metadata"])
          assert_equal("mcp:tools", params["scope"])
        end

        private

        def stub_authorization_server
          stub_request(:get, "#{ISSUER}/.well-known/oauth-authorization-server").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              issuer: ISSUER,
              token_endpoint: "#{ISSUER}/token",
              grant_types_supported: ["client_credentials"],
              token_endpoint_auth_methods_supported: ["client_secret_basic"],
              response_types_supported: ["code"],
              code_challenge_methods_supported: ["S256"],
            ),
          )

          jwt = JWT.encode(
            {
              iss: ISSUER,
              aud: MCP_URL,
              sub: "service-account",
              client_id: "service-client",
              scope: "mcp:tools",
              exp: Time.now.to_i + 3600,
            },
            SIGNING_SECRET,
            "HS256",
          )

          stub_request(:post, "#{ISSUER}/token").to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(access_token: jwt, token_type: "Bearer", expires_in: 3600),
          )
        end
      end
    end
  end
end
