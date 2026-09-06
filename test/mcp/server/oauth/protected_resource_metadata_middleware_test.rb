# frozen_string_literal: true

require "test_helper"
require "rack/builder"
require "rack/mock"

module MCP
  class Server
    module OAuth
      class ProtectedResourceMetadataMiddlewareTest < Minitest::Test
        WELL_KNOWN_PATH = "/.well-known/oauth-protected-resource/mcp"

        class RecordingApp
          attr_reader :envs

          def initialize
            @envs = []
          end

          def call(env)
            @envs << env

            [200, { "content-type" => "text/plain" }, ["downstream"]]
          end
        end

        def setup
          @metadata = ProtectedResourceMetadata.new(
            resource: "https://mcp.example.com/mcp",
            authorization_servers: ["https://as.example.com"],
            scopes_supported: ["mcp:tools"],
          )
          @app = RecordingApp.new
          @middleware = ProtectedResourceMetadataMiddleware.new(@app, @metadata)
        end

        def test_get_at_the_well_known_path_returns_the_document_with_cors_and_cache_headers
          status, headers, body = @middleware.call(env_for("GET", WELL_KNOWN_PATH))

          assert_equal(200, status)
          assert_equal("application/json", headers["content-type"])
          assert_equal("public, max-age=3600", headers["cache-control"])
          assert_equal("*", headers["access-control-allow-origin"])

          parsed = JSON.parse(body.join)

          assert_equal("https://mcp.example.com/mcp", parsed["resource"])
          assert_equal(["https://as.example.com"], parsed["authorization_servers"])
          assert_equal(["mcp:tools"], parsed["scopes_supported"])
          assert_empty(@app.envs)
        end

        def test_head_returns_the_headers_without_a_body
          status, headers, body = @middleware.call(env_for("HEAD", WELL_KNOWN_PATH))

          assert_equal(200, status)
          assert_equal("application/json", headers["content-type"])
          assert_empty(body)
        end

        def test_options_returns_a_cors_preflight
          status, headers, body = @middleware.call(env_for("OPTIONS", WELL_KNOWN_PATH))

          assert_equal(204, status)
          assert_equal("*", headers["access-control-allow-origin"])
          assert_equal("GET, HEAD, OPTIONS", headers["access-control-allow-methods"])
          assert_equal("*", headers["access-control-allow-headers"])
          assert_empty(body)
        end

        def test_post_at_the_well_known_path_is_method_not_allowed
          status, headers, body = @middleware.call(env_for("POST", WELL_KNOWN_PATH))

          assert_equal(405, status)
          assert_equal("GET, HEAD, OPTIONS", headers["allow"])
          assert_equal("method_not_allowed", JSON.parse(body.join)["error"])
          assert_empty(@app.envs)
        end

        def test_passes_every_other_path_down_untouched
          # A deeper well-known path describes another resource on this host, so it is the application's to answer.
          paths = ["/mcp", "/", "/.well-known/oauth-protected-resource", "#{WELL_KNOWN_PATH}/", "#{WELL_KNOWN_PATH}/other"]

          paths.each do |path|
            status, _headers, body = @middleware.call(env_for("GET", path))

            assert_equal(200, status, path)
            assert_equal(["downstream"], body, path)
          end

          assert_equal(paths, @app.envs.map { |env| env["PATH_INFO"] })
        end

        def test_composes_with_rack_builder_above_a_mounted_endpoint
          app = @app
          metadata = @metadata
          stack = Rack::Builder.new do
            use(ProtectedResourceMetadataMiddleware, metadata)
            map("/mcp") { run(app) }
          end.to_app

          status, _headers, body = stack.call(Rack::MockRequest.env_for(WELL_KNOWN_PATH))

          assert_equal(200, status)
          assert_equal("https://mcp.example.com/mcp", JSON.parse(body.join)["resource"])

          status, _headers, body = stack.call(Rack::MockRequest.env_for("/mcp"))

          assert_equal(200, status)
          assert_equal(["downstream"], body)
        end

        def test_requires_the_metadata_document_class
          # A look-alike that names a path but serializes as an arbitrary object would be published as the document.
          look_alike = Object.new
          look_alike.define_singleton_method(:well_known_path) { WELL_KNOWN_PATH }

          [{ "resource" => "https://mcp.example.com/mcp" }, look_alike, nil].each do |metadata|
            error = assert_raises(ArgumentError, metadata.inspect) { ProtectedResourceMetadataMiddleware.new(@app, metadata) }

            assert_includes(error.message, "metadata must be a ProtectedResourceMetadata")
          end
        end

        private

        def env_for(method, path)
          { "REQUEST_METHOD" => method, "PATH_INFO" => path, "SCRIPT_NAME" => "" }
        end
      end
    end
  end
end
