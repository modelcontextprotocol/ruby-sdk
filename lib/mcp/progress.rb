# frozen_string_literal: true

module MCP
  class Progress
    def initialize(server:, progress_token:)
      @server = server
      @progress_token = progress_token
    end

    def report(progress, total: nil, message: nil)
      return unless @progress_token

      @server.notify_progress(
        progress_token: @progress_token,
        progress: progress,
        total: total,
        message: message,
      )
    end
  end
end
