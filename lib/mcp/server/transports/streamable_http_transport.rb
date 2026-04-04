# frozen_string_literal: true

require "json"
require_relative "../../transport"

module MCP
  class Server
    module Transports
      # TODO: Resumability and redelivery with Last-Event-ID is not yet implemented.
      #   See: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#resumability-and-redelivery

      class StreamableHTTPTransport < Transport
        def initialize(server, stateless: false, session_idle_timeout: nil)
          super(server)
          # Maps `session_id` to `{ stream: stream_object, server_session: ServerSession, last_active_at: float_from_monotonic_clock }`.
          @sessions = {}
          @mutex = Mutex.new

          @stateless = stateless
          @session_idle_timeout = session_idle_timeout
          @pending_responses = {}

          if @session_idle_timeout
            if @stateless
              raise ArgumentError, "session_idle_timeout is not supported in stateless mode."
            elsif @session_idle_timeout <= 0
              raise ArgumentError, "session_idle_timeout must be a positive number."
            end
          end

          start_reaper_thread if @session_idle_timeout
        end

        REQUIRED_POST_ACCEPT_TYPES = ["application/json", "text/event-stream"].freeze
        REQUIRED_GET_ACCEPT_TYPES = ["text/event-stream"].freeze
        STREAM_WRITE_ERRORS = [IOError, Errno::EPIPE, Errno::ECONNRESET].freeze
        SESSION_REAP_INTERVAL = 60

        def handle_request(request)
          # TODO: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#security-warning

          case request.env["REQUEST_METHOD"]
          when "POST"
            handle_post(request)
          when "GET"
            handle_get(request)
          when "DELETE"
            handle_delete(request)
          else
            method_not_allowed_response
          end
        end

        def close
          @reaper_thread&.kill
          @reaper_thread = nil

          removed_sessions = @mutex.synchronize do
            @sessions.each_key.filter_map { |session_id| cleanup_session_unsafe(session_id) }
          end

          removed_sessions.each do |session|
            close_stream_safely(session[:stream])
          end
        end

        def send_notification(method, params = nil, session_id: nil)
          # Stateless mode doesn't support notifications
          raise "Stateless mode does not support notifications" if @stateless

          notification = {
            jsonrpc: "2.0",
            method: method,
          }
          notification[:params] = params if params

          streams_to_close = []

          result = @mutex.synchronize do
            if session_id
              # Send to specific session
              session = @sessions[session_id]
              next false unless session && session[:stream]

              if session_expired?(session)
                cleanup_and_collect_stream(session_id, streams_to_close)
                next false
              end

              begin
                send_to_stream(session[:stream], notification)
                true
              rescue *STREAM_WRITE_ERRORS => e
                MCP.configuration.exception_reporter.call(
                  e,
                  { session_id: session_id, error: "Failed to send notification" },
                )
                cleanup_and_collect_stream(session_id, streams_to_close)
                false
              end
            else
              # Broadcast to all connected SSE sessions
              sent_count = 0
              failed_sessions = []

              @sessions.each do |sid, session|
                next unless session[:stream]

                if session_expired?(session)
                  failed_sessions << sid
                  next
                end

                begin
                  send_to_stream(session[:stream], notification)
                  sent_count += 1
                rescue *STREAM_WRITE_ERRORS => e
                  MCP.configuration.exception_reporter.call(
                    e,
                    { session_id: sid, error: "Failed to send notification" },
                  )
                  failed_sessions << sid
                end
              end

              # Clean up failed sessions
              failed_sessions.each { |sid| cleanup_and_collect_stream(sid, streams_to_close) }

              sent_count
            end
          end

          streams_to_close.each do |stream|
            close_stream_safely(stream)
          end

          result
        end

        # Sends a server-to-client JSON-RPC request (e.g., `sampling/createMessage`) and
        # blocks until the client responds.
        #
        # Uses a `Queue` for cross-thread synchronization. This method creates a `Queue`,
        # sends the request via SSE stream, then blocks on `queue.pop`.
        # When the client POSTs a response, `handle_response` matches it by `request_id`
        # and pushes the result onto the queue, unblocking this thread.
        def send_request(method, params = nil, session_id: nil)
          if @stateless
            raise "Stateless mode does not support server-to-client requests."
          end

          unless session_id
            raise "session_id is required for server-to-client requests."
          end

          request_id = generate_request_id
          queue = Queue.new

          request = { jsonrpc: "2.0", id: request_id, method: method }
          request[:params] = params if params

          sent = false

          @mutex.synchronize do
            unless (session = @sessions[session_id])
              raise "Session not found: #{session_id}."
            end

            @pending_responses[request_id] = { queue: queue, session_id: session_id }

            if (stream = session[:stream])
              begin
                send_to_stream(stream, request)
                sent = true
              rescue *STREAM_WRITE_ERRORS
                cleanup_session_unsafe(session_id)
              end
            end
          end

          # TODO: Replace with event store + replay when resumability is implemented.
          # Resumability is a separate MCP specification feature (SSE event IDs, Last-Event-ID replay,
          # event store management) independent of sampling.
          # See: https://modelcontextprotocol.io/specification/latest/basic/transports#resumability-and-redelivery
          #
          # The TypeScript and Python SDKs buffer messages and replay on reconnect.
          # Until then, raise to prevent queue.pop from blocking indefinitely.
          unless sent
            raise "No active SSE stream for #{method} request."
          end

          response = queue.pop

          if response.is_a?(Hash) && response.key?(:error)
            raise StandardError, "Client returned an error for #{method} request (code: #{response[:error][:code]}): #{response[:error][:message]}"
          end

          if response == :session_closed
            raise "SSE session closed while waiting for #{method} response."
          end

          response
        ensure
          if request_id
            @mutex.synchronize do
              @pending_responses.delete(request_id)
            end
          end
        end

        private

        def start_reaper_thread
          @reaper_thread = Thread.new do
            loop do
              sleep(SESSION_REAP_INTERVAL)
              reap_expired_sessions
            rescue StandardError => e
              MCP.configuration.exception_reporter.call(e, error: "Session reaper error")
            end
          end
        end

        def reap_expired_sessions
          return unless @session_idle_timeout

          removed_sessions = @mutex.synchronize do
            @sessions.each_key.filter_map do |session_id|
              next unless session_expired?(@sessions[session_id])

              cleanup_session_unsafe(session_id)
            end
          end

          removed_sessions.each do |session|
            close_stream_safely(session[:stream])
          end
        end

        def send_to_stream(stream, data)
          message = data.is_a?(String) ? data : data.to_json
          stream.write("data: #{message}\n\n")
          stream.flush if stream.respond_to?(:flush)
        end

        def send_ping_to_stream(stream)
          stream.write(": ping #{Time.now.iso8601}\n\n")
          stream.flush if stream.respond_to?(:flush)
        end

        def handle_post(request)
          accept_error = validate_accept_header(request, REQUIRED_POST_ACCEPT_TYPES)
          return accept_error if accept_error

          body_string = request.body.read
          session_id = extract_session_id(request)

          body = parse_request_body(body_string)
          return body unless body.is_a?(Hash) # Error response

          if body[:method] == "initialize"
            handle_initialization(body_string, body)
          else
            return missing_session_id_response if !@stateless && !session_id

            if notification?(body)
              handle_accepted
            elsif response?(body)
              return session_not_found_response if !@stateless && !session_exists?(session_id)

              handle_response(body, session_id: session_id)
            else
              handle_regular_request(body_string, session_id)
            end
          end
        rescue StandardError => e
          MCP.configuration.exception_reporter.call(e, { request: body_string })
          [500, { "Content-Type" => "application/json" }, [{ error: "Internal server error" }.to_json]]
        end

        def handle_get(request)
          if @stateless
            return method_not_allowed_response
          end

          accept_error = validate_accept_header(request, REQUIRED_GET_ACCEPT_TYPES)
          return accept_error if accept_error

          session_id = extract_session_id(request)

          return missing_session_id_response unless session_id

          error_response = validate_and_touch_session(session_id)
          return error_response if error_response
          return session_already_connected_response if get_session_stream(session_id)

          setup_sse_stream(session_id)
        end

        def handle_delete(request)
          success_response = [200, { "Content-Type" => "application/json" }, [{ success: true }.to_json]]

          if @stateless
            # Stateless mode doesn't support sessions, so we can just return a success response
            return success_response
          end

          return missing_session_id_response unless (session_id = request.env["HTTP_MCP_SESSION_ID"])
          return session_not_found_response unless session_exists?(session_id)

          cleanup_session(session_id)

          success_response
        end

        def cleanup_session(session_id)
          session = @mutex.synchronize do
            cleanup_session_unsafe(session_id)
          end

          close_stream_safely(session[:stream]) if session
        end

        # Removes a session from `@sessions` and returns it. Does not close the stream.
        # Callers must close the stream outside the mutex to avoid holding the lock during
        # potentially blocking I/O.
        def cleanup_session_unsafe(session_id)
          session = @sessions.delete(session_id)

          # Unblock threads waiting on pending responses for this session.
          @pending_responses.each_value do |pending_response|
            if pending_response[:session_id] == session_id
              pending_response[:queue].push(:session_closed)
            end
          end

          session
        end

        def cleanup_and_collect_stream(session_id, streams_to_close)
          return unless (removed = cleanup_session_unsafe(session_id))

          streams_to_close << removed[:stream]
        end

        def close_stream_safely(stream)
          stream&.close
        rescue StandardError
          # Ignore close-related errors from already closed/broken streams.
        end

        def extract_session_id(request)
          request.env["HTTP_MCP_SESSION_ID"]
        end

        def validate_accept_header(request, required_types)
          accept_header = request.env["HTTP_ACCEPT"]
          return not_acceptable_response(required_types) unless accept_header

          accepted_types = parse_accept_header(accept_header)
          return if accepted_types.include?("*/*")

          missing_types = required_types - accepted_types
          return not_acceptable_response(required_types) unless missing_types.empty?

          nil
        end

        def parse_accept_header(header)
          header.split(",").map do |part|
            part.split(";").first.strip
          end
        end

        def not_acceptable_response(required_types)
          [
            406,
            { "Content-Type" => "application/json" },
            [{ error: "Not Acceptable: Accept header must include #{required_types.join(" and ")}" }.to_json],
          ]
        end

        def parse_request_body(body_string)
          JSON.parse(body_string, symbolize_names: true)
        rescue JSON::ParserError, TypeError
          [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
        end

        def notification?(body)
          !body[:id] && !!body[:method]
        end

        def response?(body)
          !!body[:id] && !body[:method]
        end

        # Verifies that the response came from the expected session to prevent
        # cross-session response injection if request IDs are ever leaked.
        def handle_response(body, session_id:)
          request_id = body[:id]
          @mutex.synchronize do
            if (pending_response = @pending_responses[request_id]) && pending_response[:session_id] == session_id
              if body.key?(:error)
                error = body[:error]
                pending_response[:queue].push(error: { code: error[:code], message: error[:message] })
              else
                pending_response[:queue].push(body[:result])
              end
            end
          end

          handle_accepted
        end

        def handle_initialization(body_string, body)
          session_id = nil
          server_session = nil

          unless @stateless
            session_id = SecureRandom.uuid
            server_session = ServerSession.new(server: @server, transport: self, session_id: session_id)

            @mutex.synchronize do
              @sessions[session_id] = {
                stream: nil,
                server_session: server_session,
                last_active_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
              }
            end
          end

          response = if server_session
            server_session.handle_json(body_string)
          else
            @server.handle_json(body_string)
          end

          headers = {
            "Content-Type" => "application/json",
          }

          headers["Mcp-Session-Id"] = session_id if session_id

          [200, headers, [response]]
        end

        def handle_accepted
          [202, {}, []]
        end

        def handle_regular_request(body_string, session_id)
          server_session = nil
          stream = nil

          unless @stateless
            if session_id
              error_response = validate_and_touch_session(session_id)
              return error_response if error_response

              @mutex.synchronize do
                session = @sessions[session_id]
                server_session = session[:server_session] if session
                stream = session[:stream] if session
              end
            end
          end

          response = if server_session
            server_session.handle_json(body_string)
          else
            @server.handle_json(body_string)
          end

          if stream
            send_response_to_stream(stream, response, session_id)
          else
            [200, { "Content-Type" => "application/json" }, [response]]
          end
        end

        def validate_and_touch_session(session_id)
          removed = nil

          response = @mutex.synchronize do
            next session_not_found_response unless (session = @sessions[session_id])
            next unless @session_idle_timeout

            if session_expired?(session)
              removed = cleanup_session_unsafe(session_id)
              next session_not_found_response
            end

            session[:last_active_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            nil
          end

          close_stream_safely(removed[:stream]) if removed

          response
        end

        def get_session_stream(session_id)
          @mutex.synchronize { @sessions[session_id]&.fetch(:stream, nil) }
        end

        def send_response_to_stream(stream, response, session_id)
          message = JSON.parse(response)
          send_to_stream(stream, message)
          handle_accepted
        rescue *STREAM_WRITE_ERRORS => e
          MCP.configuration.exception_reporter.call(
            e,
            { session_id: session_id, error: "Stream closed during response" },
          )
          cleanup_session(session_id)
          [200, { "Content-Type" => "application/json" }, [response]]
        end

        def session_exists?(session_id)
          @mutex.synchronize { @sessions.key?(session_id) }
        end

        def method_not_allowed_response
          [405, { "Content-Type" => "application/json" }, [{ error: "Method not allowed" }.to_json]]
        end

        def missing_session_id_response
          [400, { "Content-Type" => "application/json" }, [{ error: "Missing session ID" }.to_json]]
        end

        def session_not_found_response
          [404, { "Content-Type" => "application/json" }, [{ error: "Session not found" }.to_json]]
        end

        def session_already_connected_response
          [
            409,
            { "Content-Type" => "application/json" },
            [{ error: "Conflict: Only one SSE stream is allowed per session" }.to_json],
          ]
        end

        def setup_sse_stream(session_id)
          body = create_sse_body(session_id)

          headers = {
            "Content-Type" => "text/event-stream",
            "Cache-Control" => "no-cache",
            "Connection" => "keep-alive",
          }

          [200, headers, body]
        end

        def create_sse_body(session_id)
          proc do |stream|
            stored = store_stream_for_session(session_id, stream)
            start_keepalive_thread(session_id) if stored
          end
        end

        def store_stream_for_session(session_id, stream)
          @mutex.synchronize do
            session = @sessions[session_id]
            if session && !session[:stream]
              session[:stream] = stream
            else
              # Either session was removed, or another request already established a stream.
              stream.close
              # `stream.close` may return a truthy value depending on the stream class.
              # Explicitly return nil to guarantee a falsy return for callers.
              nil
            end
          end
        end

        def start_keepalive_thread(session_id)
          Thread.new do
            while session_active_with_stream?(session_id)
              sleep(30)
              send_keepalive_ping(session_id)
            end
          rescue StandardError => e
            MCP.configuration.exception_reporter.call(e, { session_id: session_id })
          ensure
            cleanup_session(session_id)
          end
        end

        def session_active_with_stream?(session_id)
          @mutex.synchronize { @sessions.key?(session_id) && @sessions[session_id][:stream] }
        end

        def send_keepalive_ping(session_id)
          @mutex.synchronize do
            if @sessions[session_id] && @sessions[session_id][:stream]
              send_ping_to_stream(@sessions[session_id][:stream])
            end
          end
        rescue *STREAM_WRITE_ERRORS => e
          MCP.configuration.exception_reporter.call(
            e,
            { session_id: session_id, error: "Stream closed" },
          )
          raise # Re-raise to exit the keepalive loop
        end

        def session_expired?(session)
          return false unless @session_idle_timeout

          Process.clock_gettime(Process::CLOCK_MONOTONIC) - session[:last_active_at] > @session_idle_timeout
        end
      end
    end
  end
end
