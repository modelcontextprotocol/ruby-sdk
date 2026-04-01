# frozen_string_literal: true

module MCP
  class Progress
    def initialize(notification_target:, progress_token:, related_request_id: nil)
      @notification_target = notification_target
      @progress_token = progress_token
      @related_request_id = related_request_id
    end

    def report(progress, total: nil, message: nil)
      return unless @progress_token
      return unless @notification_target

      @notification_target.notify_progress(
        progress_token: @progress_token,
        progress: progress,
        total: total,
        message: message,
        related_request_id: @related_request_id,
      )
    end
  end
end
