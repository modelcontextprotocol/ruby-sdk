# frozen_string_literal: true

require_relative "../../../serialization_utils"

module MCP
  module Auth
    module Server
      module Handlers
        class MetadataHandler
          include SerializationUtils

          def initialize(auth_server_provider:)
            @auth_server_provider = auth_server_provider
          end

          # returns [status, headers, body]
          def handle(request)
            headers = {
              "Cache-Control": "public, max-age=3600",
              "Content-Type": "application/json",
            }
            [200, headers, to_h(@auth_server_provider.oauth_metadata)]
          end
        end
      end
    end
  end
end
