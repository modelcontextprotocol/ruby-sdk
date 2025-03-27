# frozen_string_literal: true

require "test_helper"
require "mcp/server"
require "mcp/transport"

module MCP
  class TransportTest < ActiveSupport::TestCase
    class TestTransport < Transport
      def handle_request(request)
        [200, {}, ["OK"]]
      end

      def send_request(method, params = nil)
        true
      end

      def close
        true
      end
    end

    setup do
      @server = Server.new(
        name: "test_server",
        tools: [],
        prompts: [],
        resources: [],
      )
      @transport = TestTransport.new(@server)
      # Clear transports registry before each test
      Transport.instance_variable_set(:@transports, nil)
    end

    teardown do
      # Clear transports registry after each test
      Transport.instance_variable_set(:@transports, nil)
    end

    test "registers transport class" do
      Transport.register("test", TestTransport)
      assert_equal TestTransport, Transport.get("test")
    end

    test "raises error for unknown transport" do
      assert_raises(RuntimeError, "Transport unknown not found") { Transport.get("unknown") }
    end

    test "initializes with server instance" do
      assert_equal @server, @transport.instance_variable_get(:@server)
    end

    test "handles request" do
      response = @transport.handle_request(nil)
      assert_equal [200, {}, ["OK"]], response
    end

    test "sends request" do
      assert @transport.send_request("test_method", { foo: "bar" })
    end

    test "closes connection" do
      assert @transport.close
    end
  end
end
