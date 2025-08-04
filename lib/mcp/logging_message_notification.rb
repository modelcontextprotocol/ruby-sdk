# frozen_string_literal: true

require "json_rpc_handler"

module MCP
  class LoggingMessageNotification
    LOG_LEVELS = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"].freeze
    attr_reader :level

    class InvalidLevelError < StandardError
      def initialize
        super("Invalid log level provided. Valid levels are: #{LOG_LEVELS.join(", ")}")
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
      LOG_LEVELS.include?(level)
    end
  end
end
