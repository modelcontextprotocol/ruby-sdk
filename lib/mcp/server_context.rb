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

    # Sends a progress notification scoped to the originating session.
    #
    # @param progress_token [String, Integer] The token identifying the operation.
    # @param progress [Numeric] Current progress value.
    # @param total [Numeric, nil] Total expected value.
    # @param message [String, nil] Human-readable status message.
    def notify_progress(progress_token:, progress:, total: nil, message: nil)
      @notification_target.notify_progress(progress_token: progress_token, progress: progress, total: total, message: message)
    end

    # Sends a log message notification scoped to the originating session.
    #
    # @param data [Object] The log data to send.
    # @param level [String] Log level (e.g., `"debug"`, `"info"`, `"error"`).
    # @param logger [String, nil] Logger name.
    def notify_log_message(data:, level:, logger: nil)
      @notification_target.notify_log_message(data: data, level: level, logger: logger)
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
