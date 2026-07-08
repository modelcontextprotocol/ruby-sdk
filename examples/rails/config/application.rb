# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup"

require "rails"
require "action_controller/railtie"

require "mcp"

module McpRailsExample
  class Application < Rails::Application
    config.load_defaults(8.0)

    # This example has no views, assets, or database.
    config.api_only = true

    # The MCP server is built once at boot (config/routes.rb) and holds references to the tool classes in app/tools,
    # so code reloading is disabled; restart the server after changing tool or resource code.
    # A reloading app would need `config.to_prepare` and a way to swap the transport's server instead.
    config.enable_reloading = false
    config.eager_load = true

    config.logger = ActiveSupport::Logger.new($stdout)
  end
end
