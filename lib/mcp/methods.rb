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
    ELICITATION_CREATE = "elicitation/create"

    # Notification methods
    NOTIFICATIONS_INITIALIZED = "notifications/initialized"
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
        when NOTIFICATIONS_PROMPTS_LIST_CHANGED
          require_capability!(method, capabilities, :prompts)
          require_capability!(method, capabilities, :prompts, :listChanged)
        when RESOURCES_LIST, RESOURCES_TEMPLATES_LIST, RESOURCES_READ
          require_capability!(method, capabilities, :resources)
        when NOTIFICATIONS_RESOURCES_LIST_CHANGED
          require_capability!(method, capabilities, :resources)
          require_capability!(method, capabilities, :resources, :listChanged)
        when RESOURCES_SUBSCRIBE, RESOURCES_UNSUBSCRIBE, NOTIFICATIONS_RESOURCES_UPDATED
          require_capability!(method, capabilities, :resources)
          require_capability!(method, capabilities, :resources, :subscribe)
        when TOOLS_CALL, TOOLS_LIST
          require_capability!(method, capabilities, :tools)
        when NOTIFICATIONS_TOOLS_LIST_CHANGED
          require_capability!(method, capabilities, :tools)
          require_capability!(method, capabilities, :tools, :listChanged)
        when LOGGING_SET_LEVEL, NOTIFICATIONS_MESSAGE
          require_capability!(method, capabilities, :logging)
        when COMPLETION_COMPLETE
          require_capability!(method, capabilities, :completions)
        when ROOTS_LIST
          require_capability!(method, capabilities, :roots)
        when NOTIFICATIONS_ROOTS_LIST_CHANGED
          require_capability!(method, capabilities, :roots)
          require_capability!(method, capabilities, :roots, :listChanged)
        when SAMPLING_CREATE_MESSAGE
          require_capability!(method, capabilities, :sampling)
        when ELICITATION_CREATE
          require_capability!(method, capabilities, :elicitation)
        when INITIALIZE, PING, NOTIFICATIONS_INITIALIZED, NOTIFICATIONS_PROGRESS, NOTIFICATIONS_CANCELLED
          # No specific capability required for initialize, ping, progress or cancelled
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
