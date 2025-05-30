# frozen_string_literal: true

require_relative "../errors"

module MCP
  module Auth
    module Server
      class ClientRegistrationOptions
        MANDATORY_GRANT_TYPES = Set["authorization_code", "refresh_token"].freeze

        attr_accessor :enabled,
          :client_secret_expiry_seconds,
          :valid_scopes,
          :default_scopes

        def initialize(
          enabled: false,
          client_secret_expiry_seconds: nil,
          valid_scopes: nil,
          default_scopes: nil
        )
          @enabled = enabled
          @client_secret_expiry_seconds = client_secret_expiry_seconds
          @valid_scopes = valid_scopes
          @default_scopes = default_scopes
        end

        def validate_grant_types!(grant_types)
          if grant_types.to_set != MANDATORY_GRANT_TYPES
            raise Errors::InvalidGrantsError, "Grants must be '#{MANDATORY_GRANT_TYPES.to_a}'"
          end
        end

        def validate_scopes!(requested_scopes)
          return if valid_scopes.nil?

          invalid_scopes = requested_scopes - valid_scopes
          if invalid_scopes.any?
            raise Errors::InvalidScopeError, "Some requested scopes are invalid: #{invalid_scopes.join(", ")}"
          end
        end
      end

      class RevocationOptions
        attr_accessor :enabled

        def initialize(enabled: false)
          @enabled = enabled
        end
      end

      class AuthSettings
        attr_accessor :issuer_url,
          :service_documentation_url,
          :client_registration_options,
          :revocation_options,
          :required_scopes

        def initialize(
          issuer_url:,
          service_documentation_url: nil,
          client_registration_options: nil,
          revocation_options: nil,
          required_scopes: nil
        )
          raise ArgumentError, "issuer_url is required" if issuer_url.nil?

          @issuer_url = issuer_url # this is the url the mcp server is reachable at
          @service_documentation_url = service_documentation_url
          @client_registration_options = client_registration_options || ClientRegistrationOptions.new
          @revocation_options = revocation_options || RevocationOptions.new
          @required_scopes = required_scopes
        end
      end
    end
  end
end
