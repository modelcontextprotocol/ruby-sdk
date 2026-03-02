# frozen_string_literal: true

require "test_helper"

module MCP
  class Server
    module Transports
      class StdioTransportTest < ActiveSupport::TestCase
        include InstrumentationTestHelper

        setup do
          configuration = MCP::Configuration.new
          configuration.instrumentation_callback = instrumentation_helper.callback
          @server = Server.new(name: "test_server", configuration: configuration)
          @transport = StdioTransport.new(@server)
        end

        test "initializes with server and closed state" do
          server = @transport.instance_variable_get(:@server)
          assert_equal @server.object_id, server.object_id
          refute @transport.instance_variable_get(:@open)
        end

        test "processes JSON-RPC requests from stdin and sends responses to stdout" do
          request = {
            jsonrpc: "2.0",
            method: "ping",
            id: "123",
          }
          input = StringIO.new(JSON.generate(request) + "\n")
          output = StringIO.new

          original_stdin = $stdin
          original_stdout = $stdout

          begin
            $stdin = input
            $stdout = output

            thread = Thread.new { @transport.open }
            sleep(0.1)
            @transport.close
            thread.join

            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_equal("123", response[:id])
            assert_equal({}, response[:result])
            refute(@transport.instance_variable_get(:@open))
          ensure
            $stdin = original_stdin
            $stdout = original_stdout
          end
        end

        test "sends string responses to stdout" do
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send_response("test response")
            assert_equal("test response\n", output.string)
          ensure
            $stdout = original_stdout
          end
        end

        test "sends JSON responses to stdout" do
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            response = { key: "value" }
            @transport.send_response(response)
            assert_equal(JSON.generate(response) + "\n", output.string)
          ensure
            $stdout = original_stdout
          end
        end

        test "handles valid JSON-RPC requests" do
          request = {
            jsonrpc: "2.0",
            method: "ping",
            id: "123",
          }
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send(:handle_request, JSON.generate(request))
            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_nil(response[:id])
            assert_nil(response[:result])
          ensure
            $stdout = original_stdout
          end
        end

        test "handles invalid JSON requests" do
          invalid_json = "invalid json"
          output = StringIO.new
          original_stdout = $stdout

          begin
            $stdout = output
            @transport.send(:handle_request, invalid_json)
            response = JSON.parse(output.string, symbolize_names: true)
            assert_equal("2.0", response[:jsonrpc])
            assert_nil(response[:id])
            assert_equal(-32600, response[:error][:code])
            assert_equal("Invalid Request", response[:error][:message])
            assert_equal("Request must be an array or a hash", response[:error][:data])
          ensure
            $stdout = original_stdout
          end
        end
      end
    end
  end
end
