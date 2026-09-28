# frozen_string_literal: true

require "json"

module MCP
  class Server
    module OAuth
      # Rack middleware that serves a Protected Resource Metadata document (RFC 9728) at its well-known path,
      # with the CORS headers browser-based MCP clients need, and passes every other request down the stack.
      # The Rack shape of the Python SDK's `create_protected_resource_routes` and the TypeScript SDK's `mcpAuthMetadataRouter`.
      #
      # Use it at the top of the stack: the well-known path lives at the origin root, not under the MCP endpoint
      # (`/.well-known/oauth-protected-resource/mcp` for a resource at `/mcp`), so inside a `map` block it would never see that path.
      # The metadata is how unauthenticated clients bootstrap, so it belongs above any bearer enforcement.
      #
      #   metadata = MCP::Server::OAuth::ProtectedResourceMetadata.new(...)
      #   use MCP::Server::OAuth::ProtectedResourceMetadataMiddleware, metadata
      #   map("/mcp") { run(transport) }
      class ProtectedResourceMetadataMiddleware
        ALLOWED_METHODS = "GET, HEAD, OPTIONS"
        private_constant :ALLOWED_METHODS

        # @param app [#call] the rest of the Rack stack
        # @param metadata [ProtectedResourceMetadata] the document to serve, which also names the path it is served at
        def initialize(app, metadata)
          # The document is published as `to_json`, so only the class whose serialization is a validated RFC 9728 document will do.
          unless metadata.is_a?(ProtectedResourceMetadata)
            raise ArgumentError, "metadata must be a ProtectedResourceMetadata (got #{metadata.class})"
          end

          @app = app
          @well_known_path = metadata.well_known_path
          @metadata_json = metadata.to_json
        end

        def call(env)
          # An exact match only: a deeper well-known path describes another resource on this host (RFC 9728),
          # and every other path is the application's.
          return @app.call(env) unless env["PATH_INFO"] == @well_known_path

          case env["REQUEST_METHOD"]
          when "GET"
            metadata_response
          when "HEAD"
            metadata_response(head: true)
          when "OPTIONS"
            preflight_response
          else
            method_not_allowed_response
          end
        end

        private

        def metadata_response(head: false)
          headers = {
            "content-type" => "application/json",
            "cache-control" => "public, max-age=3600",
            "access-control-allow-origin" => "*",
          }

          [200, headers, head ? [] : [@metadata_json]]
        end

        def preflight_response
          headers = {
            "access-control-allow-origin" => "*",
            "access-control-allow-methods" => ALLOWED_METHODS,
            "access-control-allow-headers" => "*",
          }

          [204, headers, []]
        end

        def method_not_allowed_response
          headers = {
            "content-type" => "application/json",
            "allow" => ALLOWED_METHODS,
          }

          [405, headers, [{ error: "method_not_allowed" }.to_json]]
        end
      end
    end
  end
end
