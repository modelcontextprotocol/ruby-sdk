# frozen_string_literal: true

module MCP
  class Client
    module OAuth
      # Bounds an OAuth response body while it arrives, rather than after it has been buffered.
      # Discovery documents, registration responses, and token responses are all small by definition,
      # so a body that keeps growing is never something worth holding in memory. Matches the 4 MiB cap of
      # `MCP::Client::HTTP::MAX_MESSAGE_BYTES` and `MCP::Client::Stdio::MAX_LINE_BYTES`.
      class BoundedBody
        MAX_RESPONSE_BYTES = 4 * 1024 * 1024

        # Raised while the body is read. Each caller translates it into its own error type,
        # so this never reaches an embedder.
        class TooLargeError < StandardError; end

        # What the OAuth code reads from a response. The Faraday response itself is not passed on,
        # so a later caller cannot reach the unbounded `response.body` by accident.
        Response = Struct.new(:status, :body)

        def initialize(max_bytes: MAX_RESPONSE_BYTES)
          @max_bytes = max_bytes
          @buffer = +""
        end

        # Faraday `on_data` streaming callback. The chunks arrive decompressed: the default `Net::HTTP` adapter negotiates
        # `Accept-Encoding` itself and reads the body through `Net::HTTPResponse#inflater`, so a small compressed body
        # that expands past the cap is refused partway through the expansion rather than after it. That holds only while
        # the connection leaves `Accept-Encoding` to the adapter; see `Flow#default_http_client`.
        def on_data
          proc do |chunk, _received_bytes, _env|
            @buffer << chunk

            raise TooLargeError, too_large_message if @buffer.bytesize > @max_bytes
          end
        end

        # The status paired with the bounded body. Adapters that ignore `on_data` leave the buffer empty and deliver
        # the whole body in `response.body`, so that path is measured here instead; the bytes are already allocated by then,
        # but refusing them still keeps an over-cap document out of `JSON.parse`.
        def response_for(response)
          Response.new(response.status, bounded_body(response))
        end

        private

        def bounded_body(response)
          return @buffer unless @buffer.empty?

          body = response.body
          body = body.is_a?(String) ? body : body.to_s
          raise TooLargeError, too_large_message if body.bytesize > @max_bytes

          body
        end

        def too_large_message
          # Not "the authorization server": protected resource metadata comes from the MCP server's own origin,
          # so this message covers endpoints on both sides of the flow.
          "Response body from the OAuth endpoint exceeds #{@max_bytes} bytes"
        end
      end

      private_constant :BoundedBody
    end
  end
end
