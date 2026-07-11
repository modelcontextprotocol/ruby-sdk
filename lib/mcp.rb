# frozen_string_literal: true

require_relative "json_rpc_handler"
require_relative "mcp/configuration"
require_relative "mcp/string_utils"
require_relative "mcp/transport"
require_relative "mcp/version"

module MCP
  autoload :Annotations, "mcp/annotations"
  autoload :Apps, "mcp/apps"
  autoload :Cancellation, "mcp/cancellation"
  autoload :CancelledError, "mcp/cancelled_error"
  autoload :Client, "mcp/client"
  autoload :Content, "mcp/content"
  autoload :ErrorCodes, "mcp/error_codes"
  autoload :Icon, "mcp/icon"
  autoload :Prompt, "mcp/prompt"
  autoload :Resource, "mcp/resource"
  autoload :ResourceTemplate, "mcp/resource_template"
  autoload :ResultType, "mcp/result_type"
  autoload :Server, "mcp/server"
  autoload :ServerSession, "mcp/server_session"
  autoload :Tool, "mcp/tool"
  autoload :TraceContext, "mcp/trace_context"

  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end
  end
end
