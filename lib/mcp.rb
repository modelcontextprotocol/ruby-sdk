# frozen_string_literal: true

require_relative "json_rpc_handler"
require_relative "mcp/annotations"
require_relative "mcp/configuration"
require_relative "mcp/content"
require_relative "mcp/icon"
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
require_relative "mcp/tool/output_schema"
require_relative "mcp/tool/response"
require_relative "mcp/tool/annotations"
require_relative "mcp/transport"
require_relative "mcp/version"
require_relative "mcp/client"
require_relative "mcp/client/http"
require_relative "mcp/client/tool"

module MCP
  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end
  end
end
