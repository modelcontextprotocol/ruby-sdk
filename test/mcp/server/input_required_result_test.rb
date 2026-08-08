# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    class InputRequiredResultTest < ActiveSupport::TestCase
      test "requires at least one of input_requests or request_state" do
        assert_raises(ArgumentError) { InputRequiredResult.new }
        assert_raises(ArgumentError) { InputRequiredResult.new(input_requests: {}) }
        assert_raises(ArgumentError) { InputRequiredResult.new(request_state: 42) }
      end

      test "validates input_requests entries" do
        assert_raises(ArgumentError) { InputRequiredResult.new(input_requests: []) }
        assert_raises(ArgumentError) { InputRequiredResult.new(input_requests: { region: "not-a-hash" }) }
        assert_raises(ArgumentError) do
          InputRequiredResult.new(input_requests: { region: { method: "tools/call" } })
        end
        assert_raises(ArgumentError) do
          InputRequiredResult.new(input_requests: { region: { method: "elicitation/create", params: "x" } })
        end
      end

      test "normalizes keys, tolerates string entry keys, and freezes" do
        result = InputRequiredResult.new(input_requests: {
          region: { "method" => "elicitation/create", "params" => { message: "Which region?" } },
        })

        assert_predicate result, :frozen?
        assert_equal ["region"], result.input_requests.keys
        assert_equal "elicitation/create", result.input_requests["region"][:method]
        assert_equal({ message: "Which region?" }, result.input_requests["region"][:params])
      end

      test "#to_h serializes the SEP-2322 wire shape" do
        result = InputRequiredResult.new(
          input_requests: { region: { method: "elicitation/create", params: { message: "Which region?" } } },
          request_state: "opaque-state",
        )

        assert_equal(
          {
            resultType: "input_required",
            inputRequests: { "region" => { method: "elicitation/create", params: { message: "Which region?" } } },
            requestState: "opaque-state",
          },
          result.to_h,
        )
      end

      test "#to_h omits absent fields" do
        state_only = InputRequiredResult.new(request_state: "opaque-state")

        assert_equal({ resultType: "input_required", requestState: "opaque-state" }, state_only.to_h)
      end

      test "#required_client_capabilities maps every embedded request kind" do
        result = InputRequiredResult.new(input_requests: {
          form: { method: "elicitation/create", params: { message: "?" } },
          url: { method: "elicitation/create", params: { mode: "url", url: "https://example.com" } },
          plain_sampling: { method: "sampling/createMessage", params: { messages: [] } },
          tool_sampling: { method: "sampling/createMessage", params: { messages: [], tools: [] } },
          roots: { method: "roots/list" },
        })

        assert_equal(
          {
            elicitation: { form: {}, url: {} },
            sampling: { tools: {} },
            roots: {},
          },
          result.required_client_capabilities,
        )
      end

      test "#missing_client_capabilities returns only undeclared branches" do
        result = InputRequiredResult.new(input_requests: {
          form: { method: "elicitation/create", params: { message: "?" } },
          roots: { method: "roots/list" },
        })

        assert_equal(
          { elicitation: { form: {} }, roots: {} },
          result.missing_client_capabilities({}),
        )
        assert_equal(
          { roots: {} },
          result.missing_client_capabilities({ elicitation: { form: {} } }),
        )
        assert_empty result.missing_client_capabilities({ "elicitation" => { "form" => {} }, "roots" => {} })
      end

      test "#missing_client_capabilities treats a bare elicitation declaration as implying form" do
        # 2025 back-compat rule shared with the TypeScript and Python SDKs; an explicit
        # url-only declaration does not imply form support.
        result = InputRequiredResult.new(input_requests: {
          form: { method: "elicitation/create", params: { message: "?" } },
        })

        assert_empty result.missing_client_capabilities({ elicitation: {} })
        assert_equal(
          { elicitation: { form: {} } },
          result.missing_client_capabilities({ elicitation: { url: {} } }),
        )
      end
    end
  end
end
