# frozen_string_literal: true

module MCP
  class ServerContext
    def initialize(context, progress:, notification_target:, related_request_id: nil)
      @context = context
      @progress = progress
      @notification_target = notification_target
      @related_request_id = related_request_id
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
    def list_roots
      if @notification_target.respond_to?(:list_roots)
        @notification_target.list_roots(related_request_id: @related_request_id)
      else
        raise NoMethodError, "undefined method 'list_roots' for #{self}"
      end
    end

    # Delegates to the session so the request is scoped to the originating client.
    # Falls back to `@context` (via `method_missing`) when `@notification_target`
    # does not support sampling.
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

    def method_missing(name, ...)
      if @context.respond_to?(name)
        @context.public_send(name, ...)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @context.respond_to?(name) || super
    end
  end
end
