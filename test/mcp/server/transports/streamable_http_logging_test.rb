# frozen_string_literal: true

require "test_helper"
require "rack/mock"

module MCP
  class Server
    module Transports
      class StreamableHTTPLoggingTest < ActiveSupport::TestCase
        include InitializeParamsTestHelper

        setup do
          @server = Server.new(name: "test_server")
          @transport = StreamableHTTPTransport.new(@server)
          @transport.stubs(:start_keepalive_thread)
        end

        teardown do
          @transport.close
        end

        test "broadcasts use each session's level before the application default" do
          default_logging = LoggingMessageNotification.new(level: "warning")
          @server.logging_message_notification = default_logging
          debug_session, debug_stream = open_session
          error_session, error_stream = open_session
          _, default_stream = open_session

          set_level(debug_session, "debug")
          set_level(error_session, "error")
          _, future_stream = open_session

          ["debug", "info", "warning", "error"].each do |level|
            @server.notify_log_message(data: { message: level }, level: level, logger: "ExampleLogger")
          end

          assert_equal ["debug", "info", "warning", "error"], log_levels(debug_stream)
          assert_equal ["error"], log_levels(error_stream)
          assert_equal ["warning", "error"], log_levels(default_stream)
          assert_equal ["warning", "error"], log_levels(future_stream)
          assert_equal "ExampleLogger", messages(debug_stream).first["params"]["logger"]
          assert_same default_logging, @server.logging_message_notification
        end

        test "one session setting a level does not enable broadcasts to other sessions" do
          session, stream = open_session
          _, other_stream = open_session
          set_level(session, "info")
          _, future_stream = open_session

          @server.notify_log_message(data: "debug detail", level: "debug")
          @server.notify_log_message(data: "info detail", level: "info")

          assert_equal ["info"], log_levels(stream)
          assert_empty messages(other_stream)
          assert_empty messages(future_stream)
          assert_nil @server.logging_message_notification
        end

        private

        def request(method, payload: nil, session_id: nil)
          env = Rack::MockRequest.env_for("http://localhost/", method: method)
          env["HTTP_ACCEPT"] = "application/json, text/event-stream"
          env["HTTP_MCP_PROTOCOL_VERSION"] = "2025-11-25"
          env["HTTP_MCP_SESSION_ID"] = session_id if session_id
          if payload
            env["CONTENT_TYPE"] = "application/json"
            env["rack.input"] = StringIO.new(payload.to_json)
          end
          @transport.call(env)
        end

        def open_session
          status, headers, body = request("POST", payload: {
            jsonrpc: "2.0", id: 1, method: "initialize",
            params: initialize_params(protocolVersion: "2025-11-25"),
          })
          assert_equal 200, status
          assert_equal({}, JSON.parse(body.join).dig("result", "capabilities", "logging"))
          session_id = headers.fetch("mcp-session-id")
          status, = request("POST", session_id: session_id, payload: {
            jsonrpc: "2.0", method: "notifications/initialized",
          })
          assert_equal 202, status

          status, headers, body = request("GET", session_id: session_id)
          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]
          stream = StringIO.new
          body.call(stream)
          [session_id, stream]
        end

        def set_level(session_id, level)
          status, headers, body = request("POST", session_id: session_id, payload: {
            jsonrpc: "2.0", id: 2, method: "logging/setLevel", params: { level: level },
          })
          assert_equal 200, status
          assert_equal "text/event-stream", headers["content-type"]
          stream = StringIO.new
          body.call(stream)
          assert_equal({}, messages(stream).last["result"])
        end

        def messages(stream)
          stream.string.scan(/^data: (.+)$/).flatten.map { |json| JSON.parse(json) }
        end

        def log_levels(stream)
          messages(stream).map { |message| message["params"]["level"] }
        end
      end
    end
  end
end
