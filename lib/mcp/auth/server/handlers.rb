# frozen_string_literal: true

module MCP
  module Auth
    module Server
      module Handlers
        class << self
          def create_handlers(auth_server_provider:, request_parser:)
            {
              oauth_authorization_server: MetadataHandler.new(auth_server_provider:),
              register: RegistrationHandler.new(auth_server_provider:, request_parser:),
              authorize: AuthorizationHandler.new(auth_server_provider:, request_parser:),
              callback: CallbackHandler.new(auth_server_provider:, request_parser:),
              token: TokenHandler.new(auth_server_provider:, request_parser:),
            }
          end
        end
      end
    end
  end
end
