# frozen_string_literal: true

module MCP
  class Tool
    class Annotations
      attr_reader :destructive_hint, :idempotent_hint, :open_world_hint, :read_only_hint, :title

      def initialize(destructive_hint: true, idempotent_hint: false, open_world_hint: true, read_only_hint: false, title: nil)
        @title = title
        @read_only_hint = read_only_hint
        @destructive_hint = destructive_hint
        @idempotent_hint = idempotent_hint
        @open_world_hint = open_world_hint
      end

      def to_h
        {
          destructiveHint: destructive_hint,
          idempotentHint: idempotent_hint,
          openWorldHint: open_world_hint,
          readOnlyHint: read_only_hint,
          title: title,
        }.compact
      end
    end
  end
end
