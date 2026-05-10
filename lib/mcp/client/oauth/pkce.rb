# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module MCP
  class Client
    module OAuth
      # Generates the Proof Key for Code Exchange (PKCE) pair (RFC 7636) used to
      # bind an OAuth 2.1 authorization request to the same client that later
      # redeems the resulting authorization code. Without PKCE, an attacker
      # who steals an authorization code in transit (e.g. through a logged redirect URI)
      # can exchange it for an access token; with PKCE, the attacker would also need
      # the per-request `code_verifier`, which is never sent to the browser or any intermediary.
      #
      # MCP authorization mandates the `S256` method, so this module always returns
      # that method and refuses to expose `plain` as an option.
      #
      # The module is stateless: callers ask for a fresh pair with `generate` for
      # every authorization request and discard the result once the token endpoint has accepted it.
      #
      # - https://datatracker.ietf.org/doc/html/rfc7636
      # - https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization#authorization-code-protection
      module PKCE
        class << self
          # Generates a PKCE pair (code_verifier and S256 code_challenge).
          def generate
            verifier = SecureRandom.urlsafe_base64(64)
            challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

            { code_verifier: verifier, code_challenge: challenge, code_challenge_method: "S256" }
          end
        end
      end
    end
  end
end
