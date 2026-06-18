# frozen_string_literal: true

module MCP
  class ServerContext
    attr_reader :cancellation

    def initialize(context, progress:, notification_target:, related_request_id: nil, cancellation: nil)
      @context = context
      @progress = progress
      @notification_target = notification_target
      @related_request_id = related_request_id
      @cancellation = cancellation
    end

    def cancelled?
      !!@cancellation&.cancelled?
    end

    def raise_if_cancelled!
      @cancellation&.raise_if_cancelled!
    end

    # Reports progress for the current tool operation.
    # The notification is automatically scoped to the originating session.
    #
    # @param progress [Numeric] Current progress value.
    # @param total [Numeric, nil] Total expected value.
    # @param message [String, nil] Human-readable status message.
    def report_progress(progress, total: nil, message: nil)
      @progress.report(progress, total: total, message: message)
    end

    # Sends a log message notification scoped to the originating session.
    #
    # @param data [Object] The log data to send.
    # @param level [String] Log level (e.g., `"debug"`, `"info"`, `"error"`).
    # @param logger [String, nil] Logger name.
    # @deprecated MCP Logging (`logging/setLevel` and `notifications/message`)
    #   is deprecated as of MCP protocol version 2026-07-28 (SEP-2577).
    #   Use stderr or OpenTelemetry instead.
    def notify_log_message(data:, level:, logger: nil)
      return unless @notification_target

      @notification_target.notify_log_message(data: data, level: level, logger: logger, related_request_id: @related_request_id)
    end

    # Sends a resource updated notification scoped to the originating session.
    #
    # @param uri [String] The URI of the updated resource.
    def notify_resources_updated(uri:)
      return unless @notification_target

      @notification_target.notify_resources_updated(uri: uri)
    end

    # Delegates to the session so the request is scoped to the originating client.
    # The originating request id is stamped as `related_request_id`, satisfying
    # SEP-2260's requirement that server-to-client requests be associated with
    # the client request being processed.
    # @deprecated MCP Roots (`roots/list` and
    #   `notifications/roots/list_changed`) is deprecated as of MCP protocol
    #   version 2026-07-28 (SEP-2577). Use tool parameters, resource URIs,
    #   server configuration, or environment variables instead.
    def list_roots
      if @notification_target.respond_to?(:list_roots)
        @notification_target.list_roots(related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'list_roots' for #{self}"
      end
    end

    # Sends a `ping` request to the originating client to verify it is still responsive.
    # Per the MCP spec, the client MUST respond promptly with an empty result.
    #
    # @return [Hash] An empty hash on success.
    # @raise [Server::ValidationError] If the response `result` is not a Hash.
    # @raise [NoMethodError] If the session does not support sending pings.
    #
    # @example
    #   def self.call(server_context:)
    #     server_context.ping # => {}
    #     # ...
    #   end
    #
    # @see https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping
    def ping
      if @notification_target.respond_to?(:ping)
        @notification_target.ping(related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'ping' for #{self}"
      end
    end

    # Delegates to the session so the request is scoped to the originating client.
    # Falls back to `@context` (via `method_missing`) when `@notification_target`
    # does not support sampling.
    #
    # The originating request id is stamped as `related_request_id` and cannot be
    # overridden by callers (the literal keyword after `**kwargs` wins),
    # satisfying SEP-2260's requirement that server-to-client requests be
    # associated with the client request being processed.
    # @deprecated MCP Sampling (`sampling/createMessage`) is deprecated as of
    #   MCP protocol version 2026-07-28 (SEP-2577). Use direct LLM provider
    #   APIs instead.
    def create_sampling_message(**kwargs)
      if @notification_target.respond_to?(:create_sampling_message)
        @notification_target.create_sampling_message(**kwargs, related_request_id: @related_request_id)
      elsif @context.respond_to?(:create_sampling_message)
        @context.create_sampling_message(**kwargs, related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'create_sampling_message' for #{self}"
      end
    end

    # Delegates to the session so the request is scoped to the originating client.
    # Falls back to `@context` (via `method_missing`) when `@notification_target`
    # does not support elicitation.
    # The originating request id is stamped as a non-overridable
    # `related_request_id`, as with `create_sampling_message` (SEP-2260).
    def create_form_elicitation(**kwargs)
      if @notification_target.respond_to?(:create_form_elicitation)
        @notification_target.create_form_elicitation(**kwargs, related_request_id: @related_request_id)
      elsif @context.respond_to?(:create_form_elicitation)
        @context.create_form_elicitation(**kwargs, related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'create_form_elicitation' for #{self}"
      end
    end

    # Delegates to the session so the request is scoped to the originating client.
    # Falls back to `@context` when `@notification_target` does not support URL mode elicitation.
    # The originating request id is stamped as a non-overridable `related_request_id`,
    # as with `create_sampling_message` (SEP-2260).
    def create_url_elicitation(**kwargs)
      if @notification_target.respond_to?(:create_url_elicitation)
        @notification_target.create_url_elicitation(**kwargs, related_request_id: @related_request_id)
      elsif @context.respond_to?(:create_url_elicitation)
        @context.create_url_elicitation(**kwargs, related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'create_url_elicitation' for #{self}"
      end
    end

    # Delegates to the session so the notification is scoped to the originating client.
    def notify_elicitation_complete(**kwargs)
      if @notification_target.respond_to?(:notify_elicitation_complete)
        @notification_target.notify_elicitation_complete(**kwargs)
      elsif @context.respond_to?(:notify_elicitation_complete)
        @context.notify_elicitation_complete(**kwargs)
      else
        raise NoMethodError, "undefined method 'notify_elicitation_complete' for #{self}"
      end
    end

    # Forward arguments explicitly with `*args, **kwargs, &block` rather than the `...` forwarding syntax.
    # The gem supports Ruby 2.7.0 (see `required_ruby_version`), but RuboCop's Parser backend only runs on Ruby 2.7.8,
    # so leading-argument forwarding like `def method_missing(name, ...)` is allowed by the linter even though it
    # raises a `SyntaxError` on Ruby 2.7.0 through 2.7.2 (it was added in Ruby 2.7.3). Explicit forwarding keeps
    # this method loadable on Ruby 2.7.0.
    def method_missing(name, *args, **kwargs, &block)
      if @context.respond_to?(name)
        @context.public_send(name, *args, **kwargs, &block)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @context.respond_to?(name) || super
    end
  end
end
