# frozen_string_literal: true

require_relative "mcp/server"
require_relative "mcp/string_utils"
require_relative "mcp/serialization_utils"
require_relative "mcp/tool"
require_relative "mcp/tool/input_schema"
require_relative "mcp/tool/annotations"
require_relative "mcp/tool/response"
require_relative "mcp/content"
require_relative "mcp/resource"
require_relative "mcp/resource/contents"
require_relative "mcp/resource/embedded"
require_relative "mcp/resource_template"
require_relative "mcp/prompt"
require_relative "mcp/prompt/argument"
require_relative "mcp/prompt/message"
require_relative "mcp/prompt/result"
require_relative "mcp/version"
require_relative "mcp/configuration"
require_relative "mcp/methods"
require_relative "mcp/auth/errors"
require_relative "mcp/auth/models"
require_relative "mcp/auth/server/provider"
require_relative "mcp/auth/server/settings"
require_relative "mcp/auth/server/uri_helper"
require_relative "mcp/auth/server/client_registry"
require_relative "mcp/auth/server/state_registry"
require_relative "mcp/auth/server/request_parser"
require_relative "mcp/auth/server/providers/mcp_authorization_server_provider"
require_relative "mcp/auth/server/handlers/metadata_handler"
require_relative "mcp/auth/server/handlers/registration_handler"

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
