# frozen_string_literal: true

module MCP
  class Progress
    def initialize(notification_target:, progress_token:)
      @notification_target = notification_target
      @progress_token = progress_token
    end

    def report(progress, total: nil, message: nil)
      return unless @progress_token
      return unless @notification_target

      @notification_target.notify_progress(
        progress_token: @progress_token,
        progress: progress,
        total: total,
        message: message,
      )
    end
  end
end
