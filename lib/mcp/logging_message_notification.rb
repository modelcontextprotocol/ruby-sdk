# frozen_string_literal: true

module MCP
  class LoggingMessageNotification
    LOG_LEVEL_SEVERITY = {
      "debug" => 0,
      "info" => 1,
      "notice" => 2,
      "warning" => 3,
      "error" => 4,
      "critical" => 5,
      "alert" => 6,
      "emergency" => 7,
    }.freeze

    def initialize(level:)
      @level = level
    end

    def valid_level?
      LOG_LEVEL_SEVERITY.keys.include?(@level)
    end

    def should_notify?(log_level)
      return false unless LOG_LEVEL_SEVERITY.key?(log_level)

      LOG_LEVEL_SEVERITY[log_level] >= LOG_LEVEL_SEVERITY[@level]
    end
  end
end
