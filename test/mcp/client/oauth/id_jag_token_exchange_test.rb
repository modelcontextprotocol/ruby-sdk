# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "faraday"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class IDJAGTokenExchangeTest < Minitest::Test
        def setup
          WebMock.enable!
          @token_endpoint = "https://idp.example.com/token"
        end

        def teardown
          WebMock.reset!
        end

        def request_exchange
          IDJAGTokenExchange.request(
            token_endpoint: @token_endpoint,
            id_token: "idp-id-token",
            client_id: "idp-client",
            audience: "https://auth.example.com",
            resource: "https://srv.example.com/mcp",
          )
        end

        def test_request_sends_rfc8693_token_exchange_parameters
          stub_request(:post, @token_endpoint).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              access_token: "id-jag-assertion",
              issued_token_type: "urn:ietf:params:oauth:token-type:id-jag",
              token_type: "N_A",
            ),
          )

          assertion = request_exchange

          assert_equal("id-jag-assertion", assertion)
          assert_requested(:post, @token_endpoint) do |req|
            form = URI.decode_www_form(req.body).to_h
            form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange" &&
              form["subject_token"] == "idp-id-token" &&
              form["subject_token_type"] == "urn:ietf:params:oauth:token-type:id_token" &&
              form["requested_token_type"] == "urn:ietf:params:oauth:token-type:id-jag" &&
              form["audience"] == "https://auth.example.com" &&
              form["resource"] == "https://srv.example.com/mcp" &&
              form["client_id"] == "idp-client"
          end
        end

        def test_request_rejects_response_without_id_jag_token_type
          # A plain access token is not an ID-JAG; presenting it as a
          # jwt-bearer assertion would fail confusingly downstream.
          stub_request(:post, @token_endpoint).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(
              access_token: "ordinary-token",
              issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
            ),
          )

          error = assert_raises(IDJAGTokenExchange::ExchangeError) { request_exchange }
          assert_match(/did not issue an ID-JAG/, error.message)
        end

        def test_request_rejects_missing_access_token
          stub_request(:post, @token_endpoint).to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: JSON.generate(issued_token_type: "urn:ietf:params:oauth:token-type:id-jag"),
          )

          error = assert_raises(IDJAGTokenExchange::ExchangeError) { request_exchange }
          assert_match(/missing `access_token`/, error.message)
        end

        def test_request_raises_on_non_2xx_response
          stub_request(:post, @token_endpoint).to_return(status: 400, body: JSON.generate(error: "invalid_grant"))

          error = assert_raises(IDJAGTokenExchange::ExchangeError) { request_exchange }
          assert_match(/status 400/, error.message)
        end

        def test_request_raises_on_unparseable_response
          stub_request(:post, @token_endpoint).to_return(status: 200, body: "not json")

          error = assert_raises(IDJAGTokenExchange::ExchangeError) { request_exchange }
          assert_match(/Failed to parse/, error.message)
        end

        def test_request_raises_on_non_object_json_response
          stub_request(:post, @token_endpoint).to_return(status: 200, body: "[]")

          error = assert_raises(IDJAGTokenExchange::ExchangeError) { request_exchange }
          assert_match(/not a JSON object/, error.message)
        end
      end
    end
  end
end
