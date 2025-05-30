# frozen_string_literal: true

require_relative "../../../serialization_utils"

module MCP
  module Auth
    module Server
      module Handlers
        class MetadataHandler
          include SerializationUtils

          def initialize(oauth_metadata)
            @oauth_metadata = oauth_metadata
          end

          # returns [status, headers, body]
          def handle(request)
            headers = {
              "Cache-Control": "public, max-age=3600",
              "Content-Type": "application/json",
            }
            [200, headers, to_h(@oauth_metadata)]
          end
        end
      end
    end
  end
end
