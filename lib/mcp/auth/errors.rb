# frozen_string_literal: true

module MCP
  module Auth
    module Errors
      class InvalidScopeError < StandardError; end

      class InvalidGrantsError < StandardError; end

      class InvalidRedirectUriError < StandardError; end

      class MissingClientIdError < StandardError; end

      class RegistrationError < StandardError
        INVALID_REDIRECT_URI = "invalid_redirect_uri"
        INVALID_CLIENT_METADATA = "invalid_client_metadata"
        INVALID_SOFTWARE_STATEMENT = "invalid_software_statement"
        UNAPPROVED_SOFTARE_STATEMENT = "unapproved_software_statement"

        attr_reader :error_code

        def initialize(error_code:, message: nil)
          super(message)
          @error_code = error_code
        end
      end

      class ClientAuthenticationError < StandardError; end

      class AuthorizationError < StandardError
        INVALID_REQUEST = "invalid_request"
        UNAUTHORIZED_CLIENT = "unauthorized_client"
        ACCESS_DENIED = "access_denied"
        UNSUPPORTED_RESPONSE_TYPE = "unsupported_response_type"
        INVALID_SCOPE = "invalid_scope"
        SERVER_ERROR = "server_error"
        TEMPORARILY_UNAVAILABLE = "temporarily_unavailable"

        attr_reader :error_code

        def initialize(error_code:, message: nil)
          super(message)
          @error_code = error_code
        end

        class << self
          def invalid_request(message)
            AuthorizationError.new(error_code: INVALID_REQUEST, message:)
          end

          def invalid_grant(message)
            AuthorizationError.new(error_code: INVALID_GRANT, message:)
          end
        end
      end

      class TokenError < StandardError
        INVALID_REQUEST = "invalid_request"
        INVALID_CLIENT = "invalid_client"
        INVALID_GRANT = "invalid_grant"
        UNAUTHORIZED_CLIENT = "unauthorized_client"
        UNSUPPORTED_GRANT_TYPE = "unsupported_grant_type"
        INVALID_SCOPE = "invalid_scope"

        def initialize(error_code:, message: nil)
          super(message)
          @error_code = error_code
        end
      end
    end
  end
end
