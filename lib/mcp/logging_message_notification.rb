# frozen_string_literal: true

require "json_rpc_handler"

module MCP
  class LoggingMessageNotification
    LOG_LEVELS = {
      "debug" => 0,
      "info" => 1,
      "notice" => 2,
      "warning" => 3,
      "error" => 4,
      "critical" => 5,
      "alert" => 6,
      "emergency" => 7,
    }.freeze

    private attr_reader :level

    def initialize(level:)
      @level = level
    end

    def valid_level?
      LOG_LEVELS.keys.include?(level)
    end

    def should_notify?(log_level)
      LOG_LEVELS[log_level] >= LOG_LEVELS[level]
    end
  end
end
