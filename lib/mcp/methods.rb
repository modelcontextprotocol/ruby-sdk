# frozen_string_literal: true

module MCP
  module Methods
    INITIALIZE = "initialize"
    PING = "ping"
    LOGGING_SET_LEVEL = "logging/setLevel"

    PROMPTS_GET = "prompts/get"
    PROMPTS_LIST = "prompts/list"
    COMPLETION_COMPLETE = "completion/complete"

    RESOURCES_LIST = "resources/list"
    RESOURCES_READ = "resources/read"
    RESOURCES_TEMPLATES_LIST = "resources/templates/list"
    RESOURCES_SUBSCRIBE = "resources/subscribe"
    RESOURCES_UNSUBSCRIBE = "resources/unsubscribe"

    TOOLS_CALL = "tools/call"
    TOOLS_LIST = "tools/list"

    ROOTS_LIST = "roots/list"
    SAMPLING_CREATE_MESSAGE = "sampling/createMessage"

    # Notification methods
    NOTIFICATIONS_TOOLS_LIST_CHANGED = "notifications/tools/list_changed"
    NOTIFICATIONS_PROMPTS_LIST_CHANGED = "notifications/prompts/list_changed"
    NOTIFICATIONS_RESOURCES_LIST_CHANGED = "notifications/resources/list_changed"
    NOTIFICATIONS_RESOURCES_UPDATED = "notifications/resources/updated"
    NOTIFICATIONS_ROOTS_LIST_CHANGED = "notifications/roots/list_changed"
    NOTIFICATIONS_MESSAGE = "notifications/message"
    NOTIFICATIONS_PROGRESS = "notifications/progress"
    NOTIFICATIONS_CANCELLED = "notifications/cancelled"

    class MissingRequiredCapabilityError < StandardError
      attr_reader :method
      attr_reader :capability

      def initialize(method, capability)
        super("Server does not support #{capability} (required for #{method})")
        @method = method
        @capability = capability
      end
    end

    class << self
      def ensure_capability!(method, capabilities)
        case method
        when PROMPTS_GET, PROMPTS_LIST
          require_capability!(method, capabilities, :prompts)
        when RESOURCES_LIST, RESOURCES_TEMPLATES_LIST, RESOURCES_READ, RESOURCES_SUBSCRIBE, RESOURCES_UNSUBSCRIBE
          require_capability!(method, capabilities, :resources)
          if method == RESOURCES_SUBSCRIBE && !capabilities[:resources][:subscribe]
            raise MissingRequiredCapabilityError.new(method, :resources_subscribe)
          end
        when TOOLS_CALL, TOOLS_LIST
          require_capability!(method, capabilities, :tools)
        when SAMPLING_CREATE_MESSAGE
          require_capability!(method, capabilities, :sampling)
        when COMPLETION_COMPLETE
          require_capability!(method, capabilities, :completions)
        when LOGGING_SET_LEVEL
          require_capability!(method, capabilities, :logging)
        when INITIALIZE, PING
          # No specific capability required for initialize or ping
        end
      end

      private

      def require_capability!(method, capabilities, *keys)
        name = keys.join(".") # :resources, :subscribe -> "resources.subscribe"
        has_capability = capabilities.dig(*keys)
        return if has_capability

        raise MissingRequiredCapabilityError.new(method, name)
      end
    end
  end
end
