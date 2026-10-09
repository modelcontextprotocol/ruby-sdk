# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    module OAuth
      class AccessTokenTest < Minitest::Test
        def test_defaults
          access_token = AccessToken.new(token: "abc")

          assert_equal("abc", access_token.token)
          assert_nil(access_token.client_id)
          assert_empty(access_token.scopes)
          assert_nil(access_token.expires_at)
          assert_nil(access_token.subject)
          assert_nil(access_token.issuer)
          assert_nil(access_token.audience)
          assert_nil(access_token.resource)
          assert_empty(access_token.claims)
        end

        def test_inspect_omits_the_token
          access_token = AccessToken.new(token: "secret-credential", subject: "user-1")

          refute_includes(access_token.inspect, "secret-credential")
          assert_includes(access_token.inspect, "user-1")
        end

        def test_expired_is_false_without_expiry
          access_token = AccessToken.new(token: "abc")

          refute_predicate(access_token, :expired?)
        end

        def test_expired_is_false_before_expiry
          access_token = AccessToken.new(token: "abc", expires_at: 1000)

          refute(access_token.expired?(now: 999))
        end

        def test_expired_is_true_at_expiry
          access_token = AccessToken.new(token: "abc", expires_at: 1000)

          assert(access_token.expired?(now: 1000))
        end

        def test_expired_is_true_after_expiry
          access_token = AccessToken.new(token: "abc", expires_at: 1000)

          assert(access_token.expired?(now: 1001))
        end

        def test_scope_predicate
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:tools", "mcp:resources"])

          assert(access_token.scope?("mcp:tools"))
          assert(access_token.scope?(:"mcp:tools"))
          refute(access_token.scope?("admin"))
        end

        def test_with_scope_matcher_consults_the_matcher_on_a_copy
          access_token = AccessToken.new(token: "abc", scopes: ["mcp:all"])
          matcher = ->(required, granted) { granted.include?("mcp:all") || granted.include?(required) }

          matched = access_token.with_scope_matcher(matcher)

          assert(matched.scope?("mcp:tools"))
          refute(access_token.scope?("mcp:tools"))
          assert_equal(access_token.to_h, matched.to_h)
          assert_same(access_token, access_token.with_scope_matcher(nil))
        end

        def test_with_scope_matcher_works_on_frozen_tokens_and_keeps_the_subclass
          subclass = Class.new(AccessToken)
          access_token = subclass.new(token: "abc", scopes: ["mcp:all"]).freeze
          matcher = ->(_required, granted) { granted.include?("mcp:all") }

          matched = access_token.with_scope_matcher(matcher)

          assert(matched.scope?("mcp:tools"))
          assert_instance_of(subclass, matched)
          assert_predicate(access_token, :frozen?)
        end

        def test_to_h_omits_token_and_nil_fields
          access_token = AccessToken.new(
            token: "secret-token",
            client_id: "client-1",
            scopes: ["mcp:tools"],
            expires_at: 1000,
            subject: "user-1",
            issuer: "https://as.example.com",
            audience: "https://mcp.example.com",
            resource: "https://mcp.example.com",
            claims: { "sub" => "user-1" },
          )

          hash = access_token.to_h

          refute_includes(hash.values.join, "secret-token")
          assert_equal("client-1", hash[:client_id])
          assert_equal(["mcp:tools"], hash[:scopes])
          assert_equal(1000, hash[:expires_at])
          assert_equal("user-1", hash[:subject])
          assert_equal("https://as.example.com", hash[:issuer])
          assert_equal("https://mcp.example.com", hash[:audience])
          assert_equal("https://mcp.example.com", hash[:resource])
          assert_equal({ "sub" => "user-1" }, hash[:claims])

          minimal = AccessToken.new(token: "abc").to_h

          refute(minimal.key?(:client_id))
          refute(minimal.key?(:expires_at))
        end
      end
    end
  end
end
