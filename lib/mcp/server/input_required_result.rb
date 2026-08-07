# frozen_string_literal: true

require_relative "../methods"
require_relative "../result_type"

module MCP
  class Server
    # A multi round-trip `input_required` result (SEP-2322, MCP 2026-07-28).
    # Handlers for `tools/call`, `prompts/get`, and `resources/read` may return one instead of
    # their normal result to ask the client for additional input: `input_requests` maps server-assigned keys
    # to embedded request shapes (`elicitation/create`, `sampling/createMessage`, or `roots/list`),
    # and `request_state` is an opaque continuation string the client echoes back byte-exactly when it retries
    # the original request with `inputResponses` under the same keys.
    #
    # The server holds no memory between rounds: handlers re-run from the start on every retry and read
    # the answers via `server_context.input_responses` / `server_context.request_state`
    # (deterministic replay, matching the Python SDK). At least one of the two fields must be present;
    # a `request_state`-only result is the load-shedding form ("retry later").
    # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2322
    class InputRequiredResult
      EMBEDDABLE_METHODS = [
        Methods::ELICITATION_CREATE,
        Methods::SAMPLING_CREATE_MESSAGE,
        Methods::ROOTS_LIST,
      ].freeze

      attr_reader :input_requests, :request_state

      def initialize(input_requests: nil, request_state: nil)
        if (input_requests.nil? || input_requests.empty?) && request_state.nil?
          raise ArgumentError, "at least one of input_requests or request_state is required"
        end
        unless request_state.nil? || request_state.is_a?(String)
          raise ArgumentError, "request_state must be a String"
        end

        @input_requests = normalize_input_requests(input_requests)
        @request_state = request_state
        freeze
      end

      def to_h
        serialized_requests = @input_requests&.transform_values do |entry|
          { method: entry[:method], params: entry[:params] }.compact
        end

        {
          resultType: ResultType::INPUT_REQUIRED,
          inputRequests: serialized_requests,
          requestState: @request_state,
        }.compact
      end

      # The client capabilities required to fulfill every embedded request, merged into one nested hash.
      # The mapping matches the TypeScript SDK's `requiredClientCapabilitiesForInputRequest`:
      # `elicitation/create` with `mode: "url"` requires `elicitation.url`, any other `elicitation/create`
      # requires `elicitation.form`, `sampling/createMessage` with `tools`/`toolChoice` requires `sampling.tools`
      # (plain sampling otherwise), and `roots/list` requires `roots`.
      def required_client_capabilities
        (@input_requests || {}).values.reduce({}) do |merged, entry|
          deep_merge(merged, entry_capability(entry))
        end
      end

      # The subset of {#required_client_capabilities} the request did not declare.
      # Per SEP-2575, servers MUST NOT rely on capabilities the client has not declared,
      # so a non-empty return means the result must not be sent (`-32021`).
      def missing_client_capabilities(declared)
        missing = missing_subtree(required_client_capabilities, declared)
        prune_implied_form_elicitation(missing, declared)
      end

      private

      def normalize_input_requests(input_requests)
        return if input_requests.nil?

        raise ArgumentError, "input_requests must be a Hash" unless input_requests.is_a?(Hash)

        normalized = input_requests.each_with_object({}) do |(key, entry), result|
          raise ArgumentError, "input_requests entries must be Hashes" unless entry.is_a?(Hash)

          method = entry[:method] || entry["method"]
          unless EMBEDDABLE_METHODS.include?(method)
            raise ArgumentError,
              "input_requests entry #{key.inspect} must have a method of " \
                "#{EMBEDDABLE_METHODS.join(", ")} (got #{method.inspect})"
          end

          params = entry[:params] || entry["params"]
          raise ArgumentError, "input_requests entry params must be a Hash" unless params.nil? || params.is_a?(Hash)

          result[key.to_s] = { method: method, params: params }.compact.freeze
        end

        normalized.freeze
      end

      def entry_capability(entry)
        params = entry[:params]

        case entry[:method]
        when Methods::ELICITATION_CREATE
          mode = params && (params[:mode] || params["mode"])
          mode == "url" ? { elicitation: { url: {} } } : { elicitation: { form: {} } }
        when Methods::SAMPLING_CREATE_MESSAGE
          with_tools = params && (params.key?(:tools) || params.key?("tools") ||
            params.key?(:toolChoice) || params.key?("toolChoice"))
          with_tools ? { sampling: { tools: {} } } : { sampling: {} }
        when Methods::ROOTS_LIST
          { roots: {} }
        end
      end

      # Walks `required` and keeps only the branches absent from `declared`
      # (symbol/string tolerant on the declared side).
      def missing_subtree(required, declared)
        required.each_with_object({}) do |(name, nested), missing|
          declared_value = read_key(declared, name)

          if declared_value.nil?
            missing[name] = nested
          elsif nested.is_a?(Hash) && !nested.empty?
            nested_missing = missing_subtree(nested, declared_value)
            missing[name] = nested_missing unless nested_missing.empty?
          end
        end
      end

      # 2025 back-compat implication shared with the TypeScript and Python SDKs:
      # a bare `elicitation: {}` declaration implies form elicitation support, while
      # an explicit url-only declaration does not.
      def prune_implied_form_elicitation(missing, declared)
        elicitation_missing = missing[:elicitation]
        return missing unless elicitation_missing.is_a?(Hash) && elicitation_missing.key?(:form)

        declared_elicitation = read_key(declared, :elicitation)
        return missing unless declared_elicitation.is_a?(Hash)
        return missing unless read_key(declared_elicitation, :url).nil?

        pruned = elicitation_missing.reject { |key, _| key == :form }
        pruned.empty? ? missing.reject { |key, _| key == :elicitation } : missing.merge(elicitation: pruned)
      end

      def read_key(hash, key)
        return unless hash.is_a?(Hash)

        value = hash[key.to_sym]
        value.nil? ? hash[key.to_s] : value
      end

      def deep_merge(left, right)
        left.merge(right) do |_key, left_value, right_value|
          if left_value.is_a?(Hash) && right_value.is_a?(Hash)
            deep_merge(left_value, right_value)
          else
            right_value
          end
        end
      end
    end
  end
end
