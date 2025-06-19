# frozen_string_literal: true

require_relative "../../transport"
require "json"
require "securerandom"

module MCP
  class Server
    module Transports
      class StreamableHTTPTransport < Transport
        def initialize(server)
          super
          # { session_id => { stream: stream_object }
          @sessions = {}
          @mutex = Mutex.new
        end

        def handle_request(request)
          case request.env["REQUEST_METHOD"]
          when "POST"
            handle_post(request)
          when "GET"
            handle_get(request)
          when "DELETE"
            handle_delete(request)
          else
            [405, { "Content-Type" => "application/json" }, [{ error: "Method not allowed" }.to_json]]
          end
        end

        def close
          @mutex.synchronize do
            @sessions.each_key { |session_id| cleanup_session_unsafe(session_id) }
          end
        end

        def send_notification(notification, session_id: nil)
          @mutex.synchronize do
            if session_id
              # Send to specific session
              session = @sessions[session_id]
              return false unless session && session[:stream]

              begin
                send_to_stream(session[:stream], notification)
                true
              rescue IOError, Errno::EPIPE => e
                MCP.configuration.exception_reporter.call(
                  e,
                  { session_id: session_id, error: "Failed to send notification" },
                )
                cleanup_session_unsafe(session_id)
                false
              end
            else
              # Broadcast to all connected SSE sessions
              sent_count = 0
              failed_sessions = []

              @sessions.each do |sid, session|
                next unless session[:stream]

                begin
                  send_to_stream(session[:stream], notification)
                  sent_count += 1
                rescue IOError, Errno::EPIPE => e
                  MCP.configuration.exception_reporter.call(
                    e,
                    { session_id: sid, error: "Failed to send notification" },
                  )
                  failed_sessions << sid
                end
              end

              # Clean up failed sessions
              failed_sessions.each { |sid| cleanup_session_unsafe(sid) }

              sent_count
            end
          end
        end

        private

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
          body_string = request.body.read
          session_id = extract_session_id(request)

          body = parse_request_body(body_string)
          return body unless body.is_a?(Hash) # Error response

          if body["method"] == "initialize"
            handle_initialization(body_string, body)
          else
            handle_regular_request(body_string, session_id)
          end
        rescue StandardError => e
          MCP.configuration.exception_reporter.call(e, { request: body_string })
          [500, { "Content-Type" => "application/json" }, [{ error: "Internal server error" }.to_json]]
        end

        def handle_get(request)
          session_id = extract_session_id(request)

          return missing_session_id_response unless session_id
          return session_not_found_response unless session_exists?(session_id)

          setup_sse_stream(session_id)
        end

        def handle_delete(request)
          session_id = request.env["HTTP_MCP_SESSION_ID"]

          return [
            400,
            { "Content-Type" => "application/json" },
            [{ error: "Missing session ID" }.to_json],
          ] unless session_id

          cleanup_session(session_id)
          [200, { "Content-Type" => "application/json" }, [{ success: true }.to_json]]
        end

        def cleanup_session(session_id)
          @mutex.synchronize do
            cleanup_session_unsafe(session_id)
          end
        end

        def cleanup_session_unsafe(session_id)
          session = @sessions[session_id]
          return unless session

          begin
            session[:stream]&.close
          rescue
            nil
          end
          @sessions.delete(session_id)
        end

        def extract_session_id(request)
          request.env["HTTP_MCP_SESSION_ID"]
        end

        def parse_request_body(body_string)
          JSON.parse(body_string)
        rescue JSON::ParserError, TypeError
          [400, { "Content-Type" => "application/json" }, [{ error: "Invalid JSON" }.to_json]]
        end

        def handle_initialization(body_string, body)
          session_id = SecureRandom.uuid

          @mutex.synchronize do
            @sessions[session_id] = {
              stream: nil,
            }
          end

          response = @server.handle_json(body_string)

          headers = {
            "Content-Type" => "application/json",
            "Mcp-Session-Id" => session_id,
          }

          [200, headers, [response]]
        end

        def handle_regular_request(body_string, session_id)
          # If session ID is provided, but not in the sessions hash, return an error
          if session_id && !@sessions.key?(session_id)
            return [400, { "Content-Type" => "application/json" }, [{ error: "Invalid session ID" }.to_json]]
          end

          response = @server.handle_json(body_string)
          stream = get_session_stream(session_id) if session_id

          if stream
            send_response_to_stream(stream, response, session_id)
          else
            [200, { "Content-Type" => "application/json" }, [response]]
          end
        end

        def get_session_stream(session_id)
          @mutex.synchronize { @sessions[session_id]&.fetch(:stream, nil) }
        end

        def send_response_to_stream(stream, response, session_id)
          message = JSON.parse(response)
          send_to_stream(stream, message)
          [200, { "Content-Type" => "application/json" }, [{ accepted: true }.to_json]]
        rescue IOError, Errno::EPIPE => e
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

        def missing_session_id_response
          [400, { "Content-Type" => "application/json" }, [{ error: "Missing session ID" }.to_json]]
        end

        def session_not_found_response
          [404, { "Content-Type" => "application/json" }, [{ error: "Session not found" }.to_json]]
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
            store_stream_for_session(session_id, stream)
            start_keepalive_thread(session_id)
          end
        end

        def store_stream_for_session(session_id, stream)
          @mutex.synchronize do
            if @sessions[session_id]
              @sessions[session_id][:stream] = stream
            else
              stream.close
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
        rescue IOError, Errno::EPIPE => e
          MCP.configuration.exception_reporter.call(
            e,
            { session_id: session_id, error: "Stream closed" },
          )
          raise # Re-raise to exit the keepalive loop
        end
      end
    end
  end
end
