# frozen_string_literal: true

require "test_helper"
require "faraday"
require "socket"
require "stringio"
require "zlib"
require "mcp/client/oauth"

module MCP
  class Client
    module OAuth
      class BoundedBodyTest < Minitest::Test
        def test_on_data_rejects_chunks_that_together_exceed_the_limit
          bounded = bounded_body(max_bytes: 64)

          error = assert_raises(too_large_error) do
            4.times do
              bounded.on_data.call("a" * 32, 32, nil)
            end
          end

          assert_includes(error.message, "exceeds 64 bytes")
        end

        def test_on_data_accepts_a_body_that_stops_at_the_limit
          bounded = bounded_body(max_bytes: 64)

          2.times do
            bounded.on_data.call("a" * 32, 32, nil)
          end

          assert_equal("a" * 64, bounded.response_for(stub_response(body: "")).body)
        end

        def test_response_for_rejects_an_over_limit_body_when_the_adapter_did_not_stream
          bounded = bounded_body(max_bytes: 64)

          error = assert_raises(too_large_error) do
            bounded.response_for(stub_response(body: "a" * 65))
          end

          assert_includes(error.message, "exceeds 64 bytes")
        end

        def test_response_for_falls_back_to_the_response_body_when_the_adapter_did_not_stream
          bounded = bounded_body(max_bytes: 64)

          assert_equal("a" * 64, bounded.response_for(stub_response(body: "a" * 64)).body)
        end

        def test_response_for_coerces_a_non_string_body
          bounded = bounded_body(max_bytes: 64)

          assert_equal("", bounded.response_for(stub_response(body: nil)).body)
        end

        def test_response_for_carries_the_status_through
          bounded = bounded_body(max_bytes: 64)

          assert_equal(404, bounded.response_for(stub_response(status: 404, body: "")).status)
        end

        # Served over a real socket rather than WebMock: WebMock hands back the stubbed body verbatim
        # whatever its `Content-Encoding`, so the adapter's inflater never runs and a stubbed version
        # of this test would assert the opposite of what it looks like.
        def test_the_cap_counts_decompressed_bytes
          bounded = bounded_body(max_bytes: 1024 * 1024)
          compressed = gzip("a" * (5 * 1024 * 1024))

          assert_operator(compressed.bytesize, :<, 1024 * 1024, "the compressed body must fit under the cap")

          serving_gzip(compressed) do |url|
            assert_raises(too_large_error) do
              Faraday.new.get(url) do |req|
                req.options.on_data = bounded.on_data
                req.options.timeout = 5
              end
            end
          end
        end

        private

        def gzip(content)
          io = StringIO.new

          writer = Zlib::GzipWriter.new(io)
          writer.write(content)
          writer.close

          io.string
        end

        def serving_gzip(body)
          # Other test files load `webmock/minitest`, which blocks real connections process-wide.
          # This is the one place that needs the adapter's own request path.
          WebMock.disable! if defined?(WebMock)

          server = TCPServer.new("127.0.0.1", 0)
          thread = Thread.new do
            socket = server.accept

            loop do
              line = socket.gets

              break if line.nil? || line == "\r\n"
            end

            socket.write(
              "HTTP/1.1 200 OK\r\n" \
                "Content-Type: application/json\r\n" \
                "Content-Encoding: gzip\r\n" \
                "Content-Length: #{body.bytesize}\r\n" \
                "Connection: close\r\n\r\n",
            )
            socket.write(body)

            socket.close
          rescue IOError, SystemCallError
            nil
          end

          # Scoped to start after both are assigned, so the cleanup below never runs against `nil`
          # and a failure to open the socket surfaces as itself rather than as a `NoMethodError`.
          begin
            yield("http://127.0.0.1:#{server.addr[1]}/")
          ensure
            thread.kill
            server.close
          end
        ensure
          WebMock.enable! if defined?(WebMock)
        end

        def bounded_body(max_bytes:)
          OAuth.const_get(:BoundedBody).new(max_bytes: max_bytes)
        end

        def too_large_error
          OAuth.const_get(:BoundedBody)::TooLargeError
        end

        def stub_response(body:, status: 200)
          Struct.new(:status, :body).new(status, body)
        end
      end
    end
  end
end
