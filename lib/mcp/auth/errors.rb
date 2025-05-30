# frozen_string_literal: true

module MCP
  module Auth
    module Errors
      class InvalidScopeError < StandardError; end

      class InvalidRedirectUriError < StandardError; end
    end
  end
end
