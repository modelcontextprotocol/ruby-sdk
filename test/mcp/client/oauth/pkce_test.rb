# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "mcp/client/oauth/pkce"

module MCP
  class Client
    module OAuth
      class PKCETest < Minitest::Test
        def test_generate_returns_verifier_and_s256_challenge
          result = PKCE.generate

          assert_kind_of(String, result[:code_verifier])
          assert_operator(result[:code_verifier].length, :>=, 43)
          assert_operator(result[:code_verifier].length, :<=, 128)
          assert_equal("S256", result[:code_challenge_method])

          expected = Base64.urlsafe_encode64(Digest::SHA256.digest(result[:code_verifier]), padding: false)
          assert_equal(expected, result[:code_challenge])
        end

        def test_generate_produces_distinct_values
          a = PKCE.generate
          b = PKCE.generate

          refute_equal(a[:code_verifier], b[:code_verifier])
          refute_equal(a[:code_challenge], b[:code_challenge])
        end
      end
    end
  end
end
