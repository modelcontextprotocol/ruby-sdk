# frozen_string_literal: true

require "json"
require "uri"

module MCP
  class Client
    module OAuth
      # RFC 8693 token exchange against an enterprise identity provider, turning an IdP-issued ID token into
      # an Identity Assertion Authorization Grant (ID-JAG) per the MCP Enterprise Managed Authorization extension (SEP-990).
      # The returned ID-JAG is an opaque assertion the client then presents to the MCP authorization server with
      # the RFC 7523 `jwt-bearer` grant (see `CrossAppAccessProvider`).
      # Mirrors `requestJwtAuthorizationGrant` in the TypeScript SDK.
      #
      # - https://github.com/modelcontextprotocol/modelcontextprotocol/issues/990
      # - https://www.rfc-editor.org/rfc/rfc8693
      module IDJAGTokenExchange
        # Raised when the identity provider's token exchange fails or returns something other than an ID-JAG.
        class ExchangeError < StandardError; end

        GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
        ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token"
        ID_JAG_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id-jag"

        class << self
          # Exchanges `id_token` for an ID-JAG at the IdP's token endpoint and returns the assertion string.
          #
          # @param token_endpoint [String] The identity provider's token endpoint.
          # @param id_token [String] The IdP-issued ID token (the subject token).
          # @param client_id [String] The client's identifier at the IdP.
          # @param audience [String] The MCP authorization server's issuer identifier.
          # @param resource [String] The canonical MCP server URL (RFC 8707).
          # @param http_client [Object, nil] Faraday-compatible client; built lazily by default.
          def request(token_endpoint:, id_token:, client_id:, audience:, resource:, http_client: nil)
            http_client ||= default_http_client

            response = begin
              http_client.post(token_endpoint) do |req|
                req.headers["Content-Type"] = "application/x-www-form-urlencoded"
                req.headers["Accept"] = "application/json"
                req.body = URI.encode_www_form(
                  "grant_type" => GRANT_TYPE,
                  "subject_token" => id_token,
                  "subject_token_type" => ID_TOKEN_TYPE,
                  "requested_token_type" => ID_JAG_TOKEN_TYPE,
                  "audience" => audience,
                  "resource" => resource,
                  "client_id" => client_id,
                )
              end
            rescue Faraday::Error => e
              raise ExchangeError, "Token exchange request to #{token_endpoint} failed: #{e.class}: #{e.message}."
            end

            if response.status < 200 || response.status >= 300
              raise ExchangeError, "Identity provider token exchange returned status #{response.status}."
            end

            parse_id_jag(response)
          end

          private

          def parse_id_jag(response)
            body = response.body.is_a?(String) ? response.body : response.body.to_s
            parsed = begin
              JSON.parse(body)
            rescue JSON::ParserError => e
              raise ExchangeError, "Failed to parse token exchange response: #{e.message}."
            end

            unless parsed.is_a?(Hash)
              raise ExchangeError, "Token exchange response is not a JSON object (got #{parsed.class})."
            end

            issued_token_type = parsed["issued_token_type"]
            unless issued_token_type == ID_JAG_TOKEN_TYPE
              raise ExchangeError,
                "Token exchange did not issue an ID-JAG " \
                  "(expected issued_token_type #{ID_JAG_TOKEN_TYPE.inspect}, got #{issued_token_type.inspect})."
            end

            assertion = parsed["access_token"]
            if assertion.nil? || assertion.to_s.empty?
              raise ExchangeError, "Token exchange response is missing `access_token`."
            end

            assertion
          end

          def default_http_client
            require "faraday"
            Faraday.new do |faraday|
              faraday.headers["Accept"] = "application/json"
            end
          end
        end
      end
    end
  end
end
