# frozen_string_literal: true

module MCP
  class Server
    class Capabilities
      def initialize(capabilities_hash = nil)
        @completions = nil
        @experimental = nil
        @extensions = nil
        @logging = nil
        @prompts = nil
        @resources = nil
        @tools = nil

        if capabilities_hash
          support_completions if capabilities_hash.key?(:completions)
          support_experimental(capabilities_hash[:experimental]) if capabilities_hash.key?(:experimental)
          support_extensions(capabilities_hash[:extensions]) if capabilities_hash.key?(:extensions)
          support_logging if capabilities_hash.key?(:logging)

          if capabilities_hash.key?(:prompts)
            support_prompts
            prompts_config = capabilities_hash[:prompts] || {}
            support_prompts_list_changed if prompts_config[:listChanged]
          end

          if capabilities_hash.key?(:resources)
            support_resources
            resources_config = capabilities_hash[:resources] || {}
            support_resources_list_changed if resources_config[:listChanged]
            support_resources_subscribe if resources_config[:subscribe]
          end

          if capabilities_hash.key?(:tools)
            support_tools
            tools_config = capabilities_hash[:tools] || {}
            support_tools_list_changed if tools_config[:listChanged]
          end
        end
      end

      def support_completions
        @completions ||= {}
      end

      def support_experimental(config = {})
        @experimental = config || {}
      end

      # Declares support for capability extensions per SEP-2133. Keys are
      # extension identifiers using the reverse-DNS prefix convention
      # (e.g. `"io.modelcontextprotocol/tasks"`, `"com.example/feature"`);
      # values are arbitrary extension-defined configuration objects,
      # with an empty hash meaning "supported with no settings".
      # Repeated calls merge, so several extensions can be declared independently.
      # https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2133
      def support_extensions(extensions = {})
        @extensions = (@extensions || {}).merge(extensions || {})
      end

      def support_logging
        @logging ||= {}
      end

      def support_prompts
        @prompts ||= {}
      end

      def support_prompts_list_changed
        support_prompts
        @prompts[:listChanged] = true
      end

      def support_resources
        @resources ||= {}
      end

      def support_resources_list_changed
        support_resources
        @resources[:listChanged] = true
      end

      def support_resources_subscribe
        support_resources
        @resources[:subscribe] = true
      end

      def support_tools
        @tools ||= {}
      end

      def support_tools_list_changed
        support_tools
        @tools[:listChanged] = true
      end

      def to_h
        {
          completions: @completions,
          experimental: @experimental,
          extensions: @extensions,
          logging: @logging,
          prompts: @prompts,
          resources: @resources,
          tools: @tools,
        }.compact
      end
    end
  end
end
