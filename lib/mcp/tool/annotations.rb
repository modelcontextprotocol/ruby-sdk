# frozen_string_literal: true

module MCP
  class Tool
    class Annotations
      attr_reader :title, :read_only_hint, :destructive_hint, :idempotent_hint, :open_world_hint, :to_h

      def initialize(title: nil, read_only_hint: nil, destructive_hint: nil, idempotent_hint: nil, open_world_hint: nil)
        @title = title
        @read_only_hint = read_only_hint
        @destructive_hint = destructive_hint
        @idempotent_hint = idempotent_hint
        @open_world_hint = open_world_hint

        @to_h = {
          title:,
          readOnlyHint: read_only_hint,
          destructiveHint: destructive_hint,
          idempotentHint: idempotent_hint,
          openWorldHint: open_world_hint,
        }.compact.freeze

        freeze
      end
    end
  end
end
