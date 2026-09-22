# frozen_string_literal: true

module MCP
  module Methods
    INITIALIZE = "initialize"
    PING = "ping"
    LOGGING_SET_LEVEL = "logging/setLevel"
    # Sessionless capability discovery (MCP 2026-07-28 draft, SEP-2575).
    SERVER_DISCOVER = "server/discover"
    # Long-lived notification subscription stream (MCP 2026-07-28, SEP-2575),
    # replacing the legacy HTTP GET listening stream. Served at the transport layer
    # (Streamable HTTP modern path); transports without streaming support answer `-32601`.
    SUBSCRIPTIONS_LISTEN = "subscriptions/listen"

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

    # Skills extension (SEP-2640). `skills/list` and `skills/get` are required of every server
    # declaring `io.modelcontextprotocol/skills`; `resources/directory/read` is additionally gated
    # behind the declaration's `directoryRead` setting. All three are negotiated through
    # `capabilities.extensions` (SEP-2133) rather than a top-level capability.
    SKILLS_LIST = "skills/list"
    SKILLS_GET = "skills/get"
    RESOURCES_DIRECTORY_READ = "resources/directory/read"

    # RPC methods the stateless modern lifecycle removes (MCP 2026-07-28, SEP-2575):
    # `initialize` is replaced by the per-request `_meta` envelope plus `server/discover`,
    # `logging/setLevel` by the envelope's `logLevel` member, and `ping` and the resource
    # subscription pair by the connectionless model, which leaves nothing to keep alive
    # or subscribe on. A modern-era request naming one of these answers with `-32601`
    # Method not found (HTTP 404 on Streamable HTTP).
    MODERN_REMOVED_METHODS = [
      INITIALIZE,
      PING,
      LOGGING_SET_LEVEL,
      RESOURCES_SUBSCRIBE,
      RESOURCES_UNSUBSCRIBE,
    ].freeze

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
    NOTIFICATIONS_ELICITATION_COMPLETE = "notifications/elicitation/complete"
    # First message on a `subscriptions/listen` stream (SEP-2575): reports the subset
    # of requested notification types the server agreed to honor.
    NOTIFICATIONS_SUBSCRIPTIONS_ACKNOWLEDGED = "notifications/subscriptions/acknowledged"

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
      def notification?(method)
        method.is_a?(String) && method.start_with?("notifications/")
      end

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
        when SKILLS_LIST, SKILLS_GET
          require_extension!(method, capabilities, Skills::EXTENSION_ID)
        when RESOURCES_DIRECTORY_READ
          require_capability!(method, capabilities, :resources)
          require_extension!(method, capabilities, Skills::EXTENSION_ID, :directoryRead)
        when NOTIFICATIONS_TOOLS_LIST_CHANGED
          require_capability!(method, capabilities, :tools)
          require_capability!(method, capabilities, :tools, :listChanged)
        when LOGGING_SET_LEVEL, NOTIFICATIONS_MESSAGE
          require_capability!(method, capabilities, :logging)
        when COMPLETION_COMPLETE
          require_capability!(method, capabilities, :completions)
        when ROOTS_LIST
          require_capability!(method, capabilities, :roots)
        when SAMPLING_CREATE_MESSAGE
          require_capability!(method, capabilities, :sampling)
        when ELICITATION_CREATE
          require_capability!(method, capabilities, :elicitation)
        when INITIALIZE, PING, SERVER_DISCOVER, NOTIFICATIONS_INITIALIZED, NOTIFICATIONS_ROOTS_LIST_CHANGED,
             NOTIFICATIONS_PROGRESS, NOTIFICATIONS_CANCELLED, NOTIFICATIONS_ELICITATION_COMPLETE
          # No specific capability required.
        end
      end

      private

      # Extension declarations are keyed by reverse-DNS identifier (SEP-2133), which callers may
      # write as either a String or a Symbol, so neither `dig` alone nor a fixed key form suffices.
      # `setting` additionally requires an optional feature within the declaration to be enabled.
      def require_extension!(method, capabilities, extension_id, setting = nil)
        extensions = read_key(capabilities, :extensions)
        declaration = read_key(extensions, extension_id)
        name = setting ? "extensions.#{extension_id}.#{setting}" : "extensions.#{extension_id}"

        raise MissingRequiredCapabilityError.new(method, name) unless declaration.is_a?(Hash)
        raise MissingRequiredCapabilityError.new(method, name) if setting && read_key(declaration, setting) != true
      end

      def read_key(hash, key)
        return unless hash.is_a?(Hash)

        value = hash[key.to_sym]
        value.nil? ? hash[key.to_s] : value
      end

      def require_capability!(method, capabilities, *keys)
        name = keys.join(".") # :resources, :subscribe -> "resources.subscribe"
        has_capability = capabilities.dig(*keys)
        return if has_capability

        raise MissingRequiredCapabilityError.new(method, name)
      end
    end
  end
end
