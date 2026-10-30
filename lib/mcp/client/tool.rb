# frozen_string_literal: true

module MCP
  class Client
    # A tool as `tools/list` described it. Every member is kept as the server sent it, so what an extension
    # puts under `_meta` (MCP Apps names a tool's app under `_meta.ui`) reaches the host unchanged.
    class Tool
      attr_reader :name, :title, :description, :input_schema, :output_schema, :annotations, :icons, :execution, :meta

      def initialize(name:, description:, input_schema:, output_schema: nil, annotations: nil, title: nil, icons: nil, execution: nil, meta: nil)
        @name = name
        @title = title
        @description = description
        @input_schema = input_schema
        @output_schema = output_schema
        @annotations = annotations
        @icons = icons
        @execution = execution
        @meta = meta
      end
    end
  end
end
