# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    class RequestStateSecurityTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      KEY = ("k" * 32).freeze

      test "validates constructor arguments" do
        assert_raises(ArgumentError) { RequestStateSecurity.new(key: "short") }
        assert_raises(ArgumentError) { RequestStateSecurity.new(key: KEY, ttl: 0) }
      end

      test "seals and unseals a state bound to the originating request" do
        security = RequestStateSecurity.new(key: KEY, audience: "my_server")
        sealed = security.seal("plain-state", method: "tools/call", target: "my_tool", arguments_digest: "digest")

        assert sealed.start_with?("v1.")
        refute_includes sealed, "plain-state"
        assert_equal "plain-state",
          security.unseal(sealed, method: "tools/call", target: "my_tool", arguments_digest: "digest")
      end

      test "rejects expired tokens" do
        security = RequestStateSecurity.new(key: KEY, ttl: 60)
        sealed = security.seal("state", method: "tools/call", target: "t", arguments_digest: "d")

        travel 120 do
          assert_raises(RequestStateSecurity::InvalidStateError) do
            security.unseal(sealed, method: "tools/call", target: "t", arguments_digest: "d")
          end
        end
      end

      test "rejects claims mismatches fail-closed" do
        security = RequestStateSecurity.new(key: KEY, audience: "my_server")
        sealed = security.seal("state", method: "tools/call", target: "my_tool", arguments_digest: "digest")

        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal(sealed, method: "prompts/get", target: "my_tool", arguments_digest: "digest")
        end
        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal(sealed, method: "tools/call", target: "other_tool", arguments_digest: "digest")
        end
        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal(sealed, method: "tools/call", target: "my_tool", arguments_digest: "other")
        end

        other_audience = RequestStateSecurity.new(key: KEY, audience: "other_server")
        assert_raises(RequestStateSecurity::InvalidStateError) do
          other_audience.unseal(sealed, method: "tools/call", target: "my_tool", arguments_digest: "digest")
        end
      end

      test "rejects tampered and malformed tokens" do
        security = RequestStateSecurity.new(key: KEY)
        sealed = security.seal("state", method: "tools/call", target: "t", arguments_digest: "d")

        tampered = sealed.dup
        tampered[-1] = tampered[-1] == "A" ? "B" : "A"
        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal(tampered, method: "tools/call", target: "t", arguments_digest: "d")
        end

        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal("not-a-token", method: "tools/call", target: "t", arguments_digest: "d")
        end
        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal("v1.!!!", method: "tools/call", target: "t", arguments_digest: "d")
        end
        assert_raises(RequestStateSecurity::InvalidStateError) do
          security.unseal(nil, method: "tools/call", target: "t", arguments_digest: "d")
        end
      end

      test "rejects tokens sealed under a different key" do
        sealed = RequestStateSecurity.new(key: KEY)
          .seal("state", method: "tools/call", target: "t", arguments_digest: "d")
        other = RequestStateSecurity.new(key: "x" * 32)

        assert_raises(RequestStateSecurity::InvalidStateError) do
          other.unseal(sealed, method: "tools/call", target: "t", arguments_digest: "d")
        end
      end
    end
  end
end
