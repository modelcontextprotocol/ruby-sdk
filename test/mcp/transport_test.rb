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
