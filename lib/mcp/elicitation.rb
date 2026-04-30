# frozen_string_literal: true

module MCP
  # Builders for elicitation `requestedSchema` definitions per MCP 2025-11-25.
  # Each builder returns an instance whose `to_h` produces the JSON-Schema-shaped Hash
  # a server passes as a property value in `create_form_elicitation(requested_schema:)`.
  module Elicitation
    autoload :EnumSchema, "mcp/elicitation/enum_schema"
  end
end
