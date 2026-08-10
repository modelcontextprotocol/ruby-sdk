# frozen_string_literal: true

module MCP
  class Server
    # A one-shot, timeout-aware handoff between the thread awaiting a server-to-client response
    # and whichever thread resolves it (the client's response, a cancellation, or session teardown).
    #
    # `Queue#pop` only accepts a `timeout:` on Ruby 3.2 and later, and this gem supports 2.7,
    # so the wait is expressed with a `ConditionVariable`. The `push`/`pop` names mirror the `Queue`
    # this replaces, keeping the resolving call sites unchanged.
    #
    # First writer wins: a second `push` is ignored, so a cancellation that races a real response
    # cannot overwrite it. `pop` returns the pushed value, or the `on_timeout` result when
    # the deadline passes with nothing pushed.
    class PendingResponse
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @delivered = false
        @value = nil
      end

      # Resolves the wait. Ignored when a value was already delivered.
      def push(value)
        @mutex.synchronize do
          next if @delivered

          @delivered = true
          @value = value
          @condition.broadcast
        end
      end

      # Blocks until a value is pushed or `timeout` seconds elapse, and yields to the caller
      # on expiry so it can decide what a timeout means. `ConditionVariable#wait` can return spuriously,
      # so the deadline is re-checked against the monotonic clock.
      #
      # The expiry block runs after the lock is released: it typically cancels the request,
      # which resolves this same object, and Ruby's `Mutex` is not reentrant.
      def pop(timeout:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        expired = false

        value = @mutex.synchronize do
          until @delivered
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              expired = true
              break
            end

            @condition.wait(@mutex, remaining)
          end

          @value
        end

        expired ? yield : value
      end
    end
  end
end
