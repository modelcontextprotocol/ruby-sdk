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

    SAMPLING_CREATE_MESSAGE = "sampling/createMessage"

    # Notification methods
    NOTIFICATIONS_TOOLS_LIST_CHANGED = "notifications/tools/list_changed"
    NOTIFICATIONS_PROMPTS_LIST_CHANGED = "notifications/prompts/list_changed"
    NOTIFICATIONS_RESOURCES_LIST_CHANGED = "notifications/resources/list_changed"

    class MissingRequiredCapabilityError < StandardError
      attr_reader :method
      attr_reader :capability

      def initialize(method, capability)
        super("Server does not support #{capability} (required for #{method})")
        @method = method
        @capability = capability
      end
    end

    extend self

    def ensure_capability!(method, capabilities)
      case method
      when PROMPTS_GET, PROMPTS_LIST
        unless capabilities[:prompts]
          raise MissingRequiredCapabilityError.new(method, :prompts)
        end
      when RESOURCES_LIST, RESOURCES_TEMPLATES_LIST, RESOURCES_READ, RESOURCES_SUBSCRIBE, RESOURCES_UNSUBSCRIBE
        unless capabilities[:resources]
          raise MissingRequiredCapabilityError.new(method, :resources)
        end

        if method == RESOURCES_SUBSCRIBE && !capabilities[:resources][:subscribe]
          raise MissingRequiredCapabilityError.new(method, :resources_subscribe)
        end
      when TOOLS_CALL, TOOLS_LIST
        unless capabilities[:tools]
          raise MissingRequiredCapabilityError.new(method, :tools)
        end
      when SAMPLING_CREATE_MESSAGE
        unless capabilities[:sampling]
          raise MissingRequiredCapabilityError.new(method, :sampling)
        end
      when COMPLETION_COMPLETE
        unless capabilities[:completions]
          raise MissingRequiredCapabilityError.new(method, :completions)
        end
      when LOGGING_SET_LEVEL
        # Logging is unsupported by the Server
        unless capabilities[:logging]
          raise MissingRequiredCapabilityError.new(method, :logging)
        end
      when INITIALIZE, PING
        # No specific capability required for initialize or ping
      end
    end
  end
end
