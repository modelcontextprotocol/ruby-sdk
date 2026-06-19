# frozen_string_literal: true

require_relative "cancelled_error"

module MCP
  class Cancellation
    attr_reader :reason, :request_id

    def initialize(request_id: nil)
      @request_id = request_id
      @reason = nil
      @cancelled = false
      @callbacks = []
      @mutex = Mutex.new
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    def cancel(reason: nil)
      callbacks = @mutex.synchronize do
        return false if @cancelled

        @cancelled = true
        @reason = reason
        @callbacks.tap { @callbacks = [] }
      end

      callbacks.each do |callback|
        callback.call(reason)
      rescue StandardError => e
        MCP.configuration.exception_reporter.call(e, { error: "Cancellation callback failed" })
      end

      true
    end

    # Registers a callback invoked synchronously on the first `cancel` call.
    # If already cancelled, fires immediately.
    #
    # Returns the block itself as a handle that can be passed to `off_cancel`
    # to deregister it (e.g. when a nested request completes normally and the
    # hook should not fire on a later parent cancellation).
    def on_cancel(&block)
      fire_now = false
      @mutex.synchronize do
        if @cancelled
          fire_now = true
        else
          @callbacks << block
        end
      end

      block.call(@reason) if fire_now
      block
    end

    # Removes a previously-registered `on_cancel` callback. Returns `true`
    # if the callback was still pending (i.e. had not yet fired), `false`
    # otherwise. Safe to call with `nil`.
    def off_cancel(handle)
      return false unless handle

      @mutex.synchronize { !@callbacks.delete(handle).nil? }
    end

    def raise_if_cancelled!
      raise CancelledError.new(request_id: @request_id, reason: @reason) if cancelled?
    end
  end
end
