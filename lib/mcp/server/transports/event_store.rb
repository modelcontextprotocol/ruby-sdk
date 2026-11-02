# frozen_string_literal: true

module MCP
  class Server
    module Transports
      # The contract of the store `StreamableHTTPTransport` keeps SSE events in for resumability (MCP 2025-11-25,
      # SEP-1699): the transport stores each event it writes under the id the store assigns, and a client that
      # reconnects with `Last-Event-ID` is sent the events of that stream stored after the one it names.
      #
      # A store serves every session of the transport. Stream ids are opaque strings the transport mints,
      # one for the GET stream of a session and one for the response stream of each request; a store orders
      # the events of one stream by storage order and never has to relate streams to each other.
      # The SDK ships this contract and no store of its own. `examples/in_memory_event_store.rb` in its repository
      # is one that keeps events in the process, to copy into an application; a deployment whose reconnects may reach
      # another process implements this interface against a shared backend.
      class EventStore
        # Stores `message`, the JSON text of a JSON-RPC message, on the stream `stream_id` and returns the id
        # assigned to it, a String without line breaks that is unique across the store. `message` is `nil` for
        # the priming event that opens a stream, which is stored so that its id is a cursor like any other,
        # but is never replayed.
        def store_event(stream_id, message)
          raise NotImplementedError, "#{self.class} must implement #store_event"
        end

        # The events stored on the same stream after the event `last_event_id`, as `[stream_id, events]`
        # where `events` is an Array of `[event_id, message]` pairs in storage order, priming events left out;
        # `nil` when the store does not know `last_event_id`, which includes an event it has since dropped.
        def events_after(last_event_id)
          raise NotImplementedError, "#{self.class} must implement #events_after"
        end
      end
    end
  end
end
