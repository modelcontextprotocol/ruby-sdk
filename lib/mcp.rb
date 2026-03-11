# frozen_string_literal: true

require_relative "json_rpc_handler"
require_relative "mcp/configuration"
require_relative "mcp/string_utils"
require_relative "mcp/transport"
require_relative "mcp/version"

module MCP
  autoload :Annotations, "mcp/annotations"
  autoload :Client, "mcp/client"
  autoload :Content, "mcp/content"
  autoload :Icon, "mcp/icon"
  autoload :Prompt, "mcp/prompt"
  autoload :Resource, "mcp/resource"
  autoload :ResourceTemplate, "mcp/resource_template"
  autoload :Server, "mcp/server"
  autoload :Tool, "mcp/tool"

  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end
  end
end
