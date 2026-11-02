# frozen_string_literal: true

require "securerandom"
require "mcp"

# An `MCP::Server::Transports::EventStore` that keeps events in the process, for the single-process deployments
# `MCP::Server::Transports::StreamableHTTPTransport` serves sessions from. The SDK ships the `EventStore` contract
# and no store of its own: copy this file into an application and pass an instance as `event_store:`.
#
#   transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, event_store: InMemoryEventStore.new)
#
# The store is bounded in three ways, since it retains what handlers emit for clients that may never come back:
# each stream keeps at most `max_events_per_stream` events, dropping its oldest; at most `max_streams` streams are kept,
# and the total size of the retained messages stays under `max_bytes`, both by dropping the streams written to least recently.
# A dropped event can no longer be resumed from: a client naming it in `Last-Event-ID` is told so by the transport and has to start over.
#
# A deployment whose reconnects may reach another process needs a store on a shared backend instead.
class InMemoryEventStore < MCP::Server::Transports::EventStore
  DEFAULT_MAX_EVENTS_PER_STREAM = 1024
  DEFAULT_MAX_STREAMS = 1024
  DEFAULT_MAX_BYTES = 64 * 1024 * 1024

  def initialize(max_events_per_stream: DEFAULT_MAX_EVENTS_PER_STREAM, max_streams: DEFAULT_MAX_STREAMS, max_bytes: DEFAULT_MAX_BYTES)
    super()

    { max_events_per_stream: max_events_per_stream, max_streams: max_streams, max_bytes: max_bytes }.each do |name, value|
      raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
    end

    @max_events_per_stream = max_events_per_stream
    @max_streams = max_streams
    @max_bytes = max_bytes
    @mutex = Mutex.new
    # Maps a stream id to `{ nonce: String, sequence: Integer, bytes: Integer, events: [[event_id, message], ...] }`, in order of
    # the last write to each stream (a written stream is moved to the end), so the first entry is the one
    # to drop when the bounds are reached.
    @streams = {}
    @total_bytes = 0
  end

  # Event ids are `<stream_id>/<nonce>-<sequence>`: the stream is found again from an id without an index, the sequence orders
  # the events of a stream however many were dropped before the one the client names, and the nonce, drawn when the stream is
  # first written to, marks that life of the stream. A stream dropped and written to again gets a new nonce, so the id a client
  # still holds from the dropped one matches nothing in the new one and is refused rather than matched to a newer event;
  # and nothing in an id counts the events of other streams.
  def store_event(stream_id, message)
    stream_id = stream_id.to_s
    bytes = message.nil? ? 0 : message.bytesize

    @mutex.synchronize do
      stream = @streams.delete(stream_id) || { nonce: SecureRandom.hex(8), sequence: 0, bytes: 0, events: [] }
      stream[:sequence] += 1
      event_id = "#{stream_id}/#{stream[:nonce]}-#{stream[:sequence]}"
      stream[:events] << [event_id, message].freeze
      stream[:bytes] += bytes
      @total_bytes += bytes

      while stream[:events].size > @max_events_per_stream
        _dropped_id, dropped_message = stream[:events].shift
        dropped_bytes = dropped_message.nil? ? 0 : dropped_message.bytesize
        stream[:bytes] -= dropped_bytes
        @total_bytes -= dropped_bytes
      end

      @streams[stream_id] = stream
      drop_oldest_streams

      event_id
    end
  end

  def events_after(last_event_id)
    return unless last_event_id.is_a?(String)

    stream_id, separator, _sequence = last_event_id.rpartition("/")
    return if separator.empty?

    @mutex.synchronize do
      stream = @streams[stream_id]
      return unless stream

      index = stream[:events].index { |event_id, _message| event_id == last_event_id }
      return unless index

      events = stream[:events].drop(index + 1).reject { |_event_id, message| message.nil? }

      [stream_id, events]
    end
  end

  private

  # The stream just written is never dropped: a message larger than `max_bytes` on its own would otherwise
  # evict the stream it was stored on and make its own event id unusable at once.
  def drop_oldest_streams
    while @streams.size > 1 && (@streams.size > @max_streams || @total_bytes > @max_bytes)
      _dropped_id, dropped = @streams.shift

      @total_bytes -= dropped[:bytes]
    end
  end
end
