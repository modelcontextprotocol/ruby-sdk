# frozen_string_literal: true

module MCP
  # Values of the `resultType` result field introduced by SEP-2322 (Multi Round-Trip Requests)
  # for the MCP 2026-07-28 draft.
  #
  # A result with `resultType: "input_required"` is not a final answer: it carries an `inputRequests` map
  # of server-to-client requests (`sampling/createMessage`, `roots/list`, `elicitation/create` shapes) plus
  # an opaque `requestState` string, and the client is expected to fulfill the requests and re-issue
  # the original request with `inputResponses` and the echoed `requestState`. A missing `resultType`
  # or `"complete"` is a final result.
  #
  # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2322
  module ResultType
    COMPLETE = "complete"
    INPUT_REQUIRED = "input_required"
  end
end
