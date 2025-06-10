# frozen_string_literal: true

require "mcp"

# Stub Bugsnag
class Bugsnag
  class Report
    attr_reader :metadata

    def initialize
      @metadata = {}
    end

    def add_metadata(key, value)
      @metadata[key] = value
    end
  end

  class << self
    def notify(exception)
      report = Report.new
      yield report
      puts "Bugsnag notified of #{exception.inspect} with metadata #{report.metadata.inspect}"
    end
  end
end

require_relative "code_snippet"

puts MCP::Server.new(
  tools: [
    MCP::Tool.define(name: "error_tool") { raise "boom" },
  ],
).handle_json(
  {
    jsonrpc: "2.0",
    id: "1",
    method: "tools/call",
    params: { name: "error_tool", arguments: {} },
  }.to_json,
)
