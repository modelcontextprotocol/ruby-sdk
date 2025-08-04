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

    def should_notify?(log_level)
      LOG_LEVELS[log_level] >= LOG_LEVELS[level]
    end
  end
end
