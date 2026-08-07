# frozen_string_literal: true

require "test_helper"

module MCP
  class RequestEnvelopeTest < ActiveSupport::TestCase
    test "exposes the reserved SEP-2575 meta key names" do
      # The exact strings are wire vocabulary shared with other SDKs.
      assert_equal "io.modelcontextprotocol/protocolVersion", RequestEnvelope::PROTOCOL_VERSION_META_KEY
      assert_equal "io.modelcontextprotocol/clientInfo", RequestEnvelope::CLIENT_INFO_META_KEY
      assert_equal "io.modelcontextprotocol/clientCapabilities", RequestEnvelope::CLIENT_CAPABILITIES_META_KEY
      assert_equal "io.modelcontextprotocol/logLevel", RequestEnvelope::LOG_LEVEL_META_KEY
    end

    test ".modern? returns true when the protocolVersion claim key is present" do
      assert RequestEnvelope.modern?(modern_params)
      assert RequestEnvelope.modern?({ _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } })
    end

    test ".modern? returns true for string keys" do
      params = {
        "_meta" => {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientInfo" => { "name" => "c", "version" => "1" },
          "io.modelcontextprotocol/clientCapabilities" => {},
        },
      }

      assert RequestEnvelope.modern?(params)
    end

    test ".modern? stays true for a claimed but incomplete envelope" do
      # A claimed envelope must be validated by `parse!` (`-32602`), never silently served as legacy,
      # matching the TypeScript and Python classifiers.
      params = modern_params
      params[:_meta].delete(:"io.modelcontextprotocol/clientCapabilities")

      assert RequestEnvelope.modern?(params)
    end

    test ".modern? returns false for legacy _meta entries such as progressToken" do
      refute RequestEnvelope.modern?({ name: "echo", _meta: { progressToken: "token" } })
    end

    test ".modern? returns false without params or _meta" do
      refute RequestEnvelope.modern?(nil)
      refute RequestEnvelope.modern?({})
      refute RequestEnvelope.modern?({ name: "echo" })
      refute RequestEnvelope.modern?({ _meta: nil })
    end

    test ".parse! returns a frozen envelope with the triple and optional log level" do
      params = modern_params
      params[:_meta][:"io.modelcontextprotocol/logLevel"] = "warning"

      envelope = RequestEnvelope.parse!(params)

      assert_predicate envelope, :frozen?
      assert_equal "2026-07-28", envelope.protocol_version
      assert_equal({ name: "test_client", version: "1.0.0" }, envelope.client_info)
      assert_equal({ elicitation: {} }, envelope.client_capabilities)
      assert_equal "warning", envelope.log_level
    end

    test ".parse! leaves log_level nil when absent" do
      assert_nil RequestEnvelope.parse!(modern_params).log_level
    end

    test ".parse! raises UnsupportedProtocolVersionError with the SEP-2575 data shape" do
      params = modern_params(version: "2025-11-25")

      error = assert_raises(Server::UnsupportedProtocolVersionError) do
        RequestEnvelope.parse!(params)
      end

      assert_equal ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION, error.error_code
      assert_equal Configuration::SUPPORTED_MODERN_PROTOCOL_VERSIONS, error.error_data[:supported]
      assert_equal "2025-11-25", error.error_data[:requested]
    end

    test ".parse! accepts an envelope without the optional clientInfo" do
      # `clientInfo` became optional after the SEP was finalized (spec PR #3002);
      # a conformant client configured not to identify itself must not be rejected.
      params = modern_params
      params[:_meta].delete(:"io.modelcontextprotocol/clientInfo")

      envelope = RequestEnvelope.parse!(params)

      assert_nil envelope.client_info
      assert_equal "2026-07-28", envelope.protocol_version
      assert_equal({ elicitation: {} }, envelope.client_capabilities)
    end

    test ".parse! raises Invalid params naming the missing key when clientCapabilities is absent" do
      params = modern_params
      params[:_meta].delete(:"io.modelcontextprotocol/clientCapabilities")

      error = assert_raises(Server::RequestHandlerError) do
        RequestEnvelope.parse!(params)
      end

      assert_equal :invalid_params, error.error_type
      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, error.error_code
      assert_includes error.message, "io.modelcontextprotocol/clientCapabilities"
      refute_includes error.message, "io.modelcontextprotocol/protocolVersion"
    end

    test ".parse! raises Invalid params when a required field has the wrong type" do
      params = modern_params
      params[:_meta][:"io.modelcontextprotocol/clientCapabilities"] = "not-a-hash"

      error = assert_raises(Server::RequestHandlerError) do
        RequestEnvelope.parse!(params)
      end

      assert_equal :invalid_params, error.error_type
      assert_equal JsonRpcHandler::ErrorCode::INVALID_PARAMS, error.error_code
    end

    test ".parse! raises Invalid params when the optional clientInfo has the wrong type" do
      params = modern_params
      params[:_meta][:"io.modelcontextprotocol/clientInfo"] = "not-a-hash"

      error = assert_raises(Server::RequestHandlerError) do
        RequestEnvelope.parse!(params)
      end

      assert_equal :invalid_params, error.error_type
      assert_includes error.message, "io.modelcontextprotocol/clientInfo"
    end

    private

    def modern_params(version: "2026-07-28")
      {
        name: "echo",
        _meta: {
          "io.modelcontextprotocol/protocolVersion": version,
          "io.modelcontextprotocol/clientInfo": { name: "test_client", version: "1.0.0" },
          "io.modelcontextprotocol/clientCapabilities": { elicitation: {} },
        },
      }
    end
  end
end
