# frozen_string_literal: true

require "mcp"

# Minimally mock Bugsnag for the test
module Bugsnag
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

b = binding
eval(File.read("code_snippet.rb"), b)
server = b.local_variable_get(:server)

server.define_tool(name: "error_tool") { raise "boom" }

puts server.handle_json({
  jsonrpc: "2.0",
  id: "1",
  method: "tools/call",
  params: { name: "error_tool", arguments: {} },
}.to_json)
