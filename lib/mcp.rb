# frozen_string_literal: true

require_relative "mcp/configuration"
require_relative "mcp/content"
require_relative "mcp/instrumentation"
require_relative "mcp/methods"
require_relative "mcp/prompt"
require_relative "mcp/prompt/argument"
require_relative "mcp/prompt/message"
require_relative "mcp/prompt/result"
require_relative "mcp/resource"
require_relative "mcp/resource/contents"
require_relative "mcp/resource/embedded"
require_relative "mcp/resource_template"
require_relative "mcp/server"
require_relative "mcp/server/transports/streamable_http_transport"
require_relative "mcp/server/transports/stdio_transport"
require_relative "mcp/string_utils"
require_relative "mcp/tool"
require_relative "mcp/tool/input_schema"
require_relative "mcp/tool/response"
require_relative "mcp/tool/annotations"
require_relative "mcp/transport"
require_relative "mcp/version"

module MCP
  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end
  end

  class Annotations
    attr_reader :audience, :priority

    def initialize(audience: nil, priority: nil)
      @audience = audience
      @priority = priority
    end
  end
end
