# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "mcp/client/oauth/discovery"
require_relative "token_verifier"

module MCP
  class Server
    module OAuth
      # Verifies access tokens by asking the authorization server via OAuth 2.0 Token Introspection (RFC 7662).
      # Works with opaque tokens and needs no extra dependencies.
      #
      #   verifier = MCP::Server::OAuth::IntrospectionVerifier.new(
      #     introspection_endpoint: "https://as.example.com/oauth/introspect",
      #     client_id: "mcp-resource-server",
      #     client_secret: ENV["INTROSPECTION_CLIENT_SECRET"],
      #     resource_metadata: metadata, # the ProtectedResourceMetadata this server publishes; its `resource` is the expected `aud`
      #   )
      #
      # Every `verify` call hits the endpoint; responses are intentionally not cached so token revocation takes
      # effect within the authorization server's own latency, not ours.
      #
      # `audience` is required: the introspection response's `aud` (or `resource`) must cover it,
      # which is the RFC 8707 audience check the MCP authorization specification demands of every resource server.
      # It keeps a token issued for another resource from being replayed here. An authorization server that cannot
      # audience-bind its tokens needs a custom verifier, and the deployment should understand what it is giving up.
      class IntrospectionVerifier < TokenVerifier
        # Raised when the introspection endpoint is unreachable or misbehaves. Deliberately not an `OAuth::Error`:
        # an unavailable authorization server is an internal failure (HTTP 500), not a problem with the client's token.
        class IntrospectionError < StandardError; end

        # Named after the RFC 7591 `token_endpoint_auth_method` values, the same vocabulary the client side uses.
        CLIENT_AUTH_METHODS = [:client_secret_basic, :client_secret_post, :none].freeze
        private_constant :CLIENT_AUTH_METHODS

        def initialize(
          introspection_endpoint:,
          resource_metadata:,
          client_id: nil,
          client_secret: nil,
          client_auth_method: :client_secret_basic,
          open_timeout: 5,
          read_timeout: 5
        )
          super()

          unless Client::OAuth::Discovery.secure_url?(introspection_endpoint)
            raise ArgumentError, "introspection_endpoint must use https (http is allowed only on loopback): #{introspection_endpoint.inspect}"
          end
          # The RFC 8707 audience check keeps tokens issued for other resources from being replayed against this server;
          # the expected value is the `resource` of the document this server publishes.
          audience = resource_from(resource_metadata)
          require_expected_claim!(:audience, audience)
          require_positive_number!(:open_timeout, open_timeout)
          require_positive_number!(:read_timeout, read_timeout)
          unless CLIENT_AUTH_METHODS.include?(client_auth_method)
            raise ArgumentError, "client_auth_method must be one of #{CLIENT_AUTH_METHODS.join(", ")}"
          end
          if client_auth_method != :none && client_id.nil?
            raise ArgumentError, "client_id is required for client_auth_method #{client_auth_method.inspect}"
          end

          @introspection_endpoint = introspection_endpoint
          @client_id = client_id
          @client_secret = client_secret
          @client_auth_method = client_auth_method
          @audience = audience
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        def verify(token)
          claims = introspect(token)

          raise InvalidTokenError, "Token is not active" unless claims["active"] == true

          validate_audience!(claims)

          access_token = access_token_from_claims(token, claims, resource: @audience)
          # An active-but-expired introspection response would be an authorization server bug, but expiry is this verifier's contractual duty,
          # so it is enforced here rather than trusted.
          raise InvalidTokenError, "Token expired" if access_token.expired?

          access_token
        end

        private

        def introspect(token)
          uri = URI.parse(@introspection_endpoint)
          request = Net::HTTP::Post.new(uri.request_uri)
          request["Accept"] = "application/json"

          form = { "token" => token }
          case @client_auth_method
          when :client_secret_basic
            request["Authorization"] = "Basic #{basic_credentials}"
          when :client_secret_post
            form["client_id"] = @client_id
            form["client_secret"] = @client_secret.to_s
          end
          request.set_form_data(form)

          body = "".dup

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
            http.request(request) do |response|
              unless response.is_a?(Net::HTTPOK)
                raise IntrospectionError, "Introspection endpoint responded with status #{response.code}"
              end

              response.read_body do |chunk|
                body << chunk
                if body.bytesize > MAX_UPSTREAM_RESPONSE_BYTES
                  raise IntrospectionError, "Introspection response exceeded #{MAX_UPSTREAM_RESPONSE_BYTES} bytes"
                end
              end
            end
          end

          parsed = JSON.parse(body)
          unless parsed.is_a?(Hash)
            raise IntrospectionError, "Introspection endpoint returned a non-object JSON document"
          end

          parsed
        rescue JSON::ParserError
          raise IntrospectionError, "Introspection endpoint returned invalid JSON"
        end

        # RFC 6749 Section 2.3.1: the client id and secret are form-urlencoded before being joined and base64-encoded,
        # so a `:` or another reserved character in either survives the round trip; `Net::HTTP#basic_auth` skips that step.
        def basic_credentials
          credentials = "#{URI.encode_www_form_component(@client_id)}:#{URI.encode_www_form_component(@client_secret.to_s)}"

          [credentials].pack("m0")
        end

        def validate_audience!(claims)
          audience_values = Array(claims["aud"]) + Array(claims["resource"])
          return if audience_values.include?(@audience)

          raise InvalidTokenError, "Invalid audience"
        end
      end
    end
  end
end
