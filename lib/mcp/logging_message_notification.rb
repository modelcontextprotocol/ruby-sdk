# frozen_string_literal: true

require "json_rpc_handler"

module MCP
  class LoggingMessageNotification
    LOG_LEVELS = {
      "emergency" => 0,
      "alert" => 1,
      "critical" => 2,
      "error" => 3,
      "warning" => 4,
      "notice" => 5,
      "info" => 6,
      "debug" => 7,
    }.freeze

    attr_reader :level

    class InvalidLevelError < StandardError
      def initialize
        super("Invalid log level provided. Valid levels are: #{LOG_LEVELS.keys.join(", ")}")
        @code = JsonRpcHandler::ErrorCode::InvalidParams
      end
    end

    class NotSpecifiedLevelError < StandardError
      def initialize
        super("Log level not specified. Please set a valid log level.")
        @code = JsonRpcHandler::ErrorCode::InternalError
      end
    end

    def initialize(level:)
      @level = level
    end

    def valid_level?
      LOG_LEVELS.keys.include?(level)
    end

    def should_notify?(notification_level:)
      LOG_LEVELS[notification_level] <= LOG_LEVELS[level]
    end
  end
end
