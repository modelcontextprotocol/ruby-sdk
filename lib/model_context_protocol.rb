# typed: strict
# frozen_string_literal: true

require_relative "model_context_protocol/shared/version"
require_relative "model_context_protocol/shared/configuration"
require_relative "model_context_protocol/shared/instrumentation"
require_relative "model_context_protocol/shared/methods"
require_relative "model_context_protocol/shared/transport"
require_relative "model_context_protocol/shared/content"
require_relative "model_context_protocol/shared/string_utils"

require_relative "model_context_protocol/shared/resource"
require_relative "model_context_protocol/shared/resource/contents"
require_relative "model_context_protocol/shared/resource/embedded"
require_relative "model_context_protocol/shared/resource_template"

require_relative "model_context_protocol/shared/tool"
require_relative "model_context_protocol/shared/tool/input_schema"
require_relative "model_context_protocol/shared/tool/response"
require_relative "model_context_protocol/shared/tool/annotations"

require_relative "model_context_protocol/shared/prompt"
require_relative "model_context_protocol/shared/prompt/argument"
require_relative "model_context_protocol/shared/prompt/message"
require_relative "model_context_protocol/shared/prompt/result"

require_relative "model_context_protocol/server"
require_relative "model_context_protocol/server/transports/stdio"

module ModelContextProtocol
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

MCP = ModelContextProtocol
