# frozen_string_literal: true

module MCP
  class ServerContext
    def initialize(context, progress:, notification_target:)
      @context = context
      @progress = progress
      @notification_target = notification_target
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

      @notification_target.notify_log_message(data: data, level: level, logger: logger)
    end

    # Delegates to the session so the request is scoped to the originating client.
    # Falls back to `@context` (via `method_missing`) when `@notification_target`
    # does not support sampling.
    def create_sampling_message(**kwargs)
      if @notification_target.respond_to?(:create_sampling_message)
        @notification_target.create_sampling_message(**kwargs)
      elsif @context.respond_to?(:create_sampling_message)
        @context.create_sampling_message(**kwargs)
      else
        raise NoMethodError, "undefined method 'create_sampling_message' for #{self}"
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
