# frozen_string_literal: true

module MCP
  class ServerContext
    def initialize(context, progress:)
      @context = context
      @progress = progress
    end

    def report_progress(progress, total: nil, message: nil)
      @progress.report(progress, total: total, message: message)
    end

    def method_missing(name, ...)
      if @context.respond_to?(name)
        @context.public_send(name, ...)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @context.respond_to?(name) || super
    end
  end
end
