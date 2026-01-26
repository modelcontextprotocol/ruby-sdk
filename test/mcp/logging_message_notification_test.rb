# frozen_string_literal: true

require "test_helper"

module MCP
  class LoggingMessageNotificationTest < ActiveSupport::TestCase
    test "valid_level? returns true for valid levels" do
      LoggingMessageNotification::LOG_LEVEL_SEVERITY.keys.each do |level|
        logging_message_notification = LoggingMessageNotification.new(level: level)
        assert logging_message_notification.valid_level?, "#{level} should be valid"
      end
    end

    test "valid_level? returns false for invalid levels" do
      invalid_levels = ["invalid", 1, "", nil, :fatal]
      invalid_levels.each do |level|
        logging_message_notification = LoggingMessageNotification.new(level: level)
        refute logging_message_notification.valid_level?, "#{level} should be invalid"
      end
    end

    test "should_notify? returns true when notification level is higher priority than threshold level or equals to it" do
      logging_message_notification = LoggingMessageNotification.new(level: "warning")
      assert logging_message_notification.should_notify?("warning")
      assert logging_message_notification.should_notify?("error")
      assert logging_message_notification.should_notify?("critical")
      assert logging_message_notification.should_notify?("alert")
      assert logging_message_notification.should_notify?("emergency")
    end

    test "should_notify? returns false when notification level is lower priority than threshold level" do
      logging_message_notification = LoggingMessageNotification.new(level: "warning")
      refute logging_message_notification.should_notify?("notice")
      refute logging_message_notification.should_notify?("info")
      refute logging_message_notification.should_notify?("debug")
    end

    test "should_notify? returns false for invalid log levels" do
      logging_message_notification = LoggingMessageNotification.new(level: "warning")
      refute logging_message_notification.should_notify?("invalid")
      refute logging_message_notification.should_notify?(1)
      refute logging_message_notification.should_notify?("")
      refute logging_message_notification.should_notify?(nil)
      refute logging_message_notification.should_notify?(:fatal)
    end
  end
end
