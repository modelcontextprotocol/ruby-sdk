# frozen_string_literal: true

require_relative "errors"

module MCP
  module Auth
    module Models
      # See https://datatracker.ietf.org/doc/html/rfc6749#section-5.1
      class OAuthToken
        attr_accessor :access_token,
          :token_type,
          :expires_in,
          :scope,
          :refresh_token

        def initialize(
          access_token:,
          token_type: "bearer",
          expires_in: nil,
          scope: nil,
          refresh_token: nil
        )
          raise ArgumentError, "token_type must be 'bearer'" unless token_type == "bearer"

          @access_token = access_token
          @token_type = token_type
          @expires_in = expires_in
          @scope = scope
          @refresh_token = refresh_token
        end
      end

      # Represents OAuth 2.0 Dynamic Client Registration metadata as defined in RFC 7591.
      # See https://datatracker.ietf.org/doc/html/rfc7591#section-2
      class OAuthClientMetadata
        attr_accessor :redirect_uris,
          :token_endpoint_auth_method,
          :grant_types,
          :response_types,
          :scope,
          # unused, keeping for future use
          :client_name,
          :client_uri,
          :logo_uri,
          :contacts,
          :tos_uri,
          :policy_uri,
          :jwks_uri,
          :jwks,
          :software_id,
          :software_version

        # Supported values for token_endpoint_auth_method
        VALID_TOKEN_ENDPOINT_AUTH_METHODS = ["none", "client_secret_post"].freeze
        # Supported grant types
        VALID_GRANT_TYPES = ["authorization_code", "refresh_token"].freeze
        # Supported response types
        VALID_RESPONSE_TYPES = ["code"].freeze

        DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD = "client_secret_post"
        DEFAULT_GRANT_TYPES = ["authorization_code", "refresh_token"].freeze
        DEFAULT_RESPONSE_TYPES = ["code"].freeze

        def initialize(
          redirect_uris:,
          token_endpoint_auth_method: DEFAULT_TOKEN_ENDPOINT_AUTH_METHOD,
          grant_types: DEFAULT_GRANT_TYPES.dup,
          response_types: DEFAULT_RESPONSE_TYPES.dup,
          scope: nil,
          client_name: nil,
          client_uri: nil,
          logo_uri: nil,
          contacts: nil,
          tos_uri: nil,
          policy_uri: nil,
          jwks_uri: nil,
          jwks: nil,
          software_id: nil,
          software_version: nil
        )
          raise ArgumentError, "redirect_uris must be a non-empty array" if !redirect_uris.is_a?(Array) || redirect_uris.empty?

          @redirect_uris = redirect_uris

          unless VALID_TOKEN_ENDPOINT_AUTH_METHODS.include?(token_endpoint_auth_method)
            raise ArgumentError, "Invalid token_endpoint_auth_method: #{token_endpoint_auth_method}. Valid methods are: #{VALID_TOKEN_ENDPOINT_AUTH_METHODS.join(", ")}"
          end

          @token_endpoint_auth_method = token_endpoint_auth_method

          grant_types.each do |gt|
            unless VALID_GRANT_TYPES.include?(gt)
              raise ArgumentError, "Invalid grant_type: #{gt}. Valid grant types are: #{VALID_GRANT_TYPES.join(", ")}"
            end
          end
          @grant_types = grant_types

          response_types.each do |rt|
            unless VALID_RESPONSE_TYPES.include?(rt)
              raise ArgumentError, "Invalid response_type: #{rt}. Valid response types are: #{VALID_RESPONSE_TYPES.join(", ")}"
            end
          end
          @response_types = response_types

          @scope = scope
          @client_name = client_name
          @client_uri = client_uri
          @logo_uri = logo_uri
          @contacts = contacts
          @tos_uri = tos_uri
          @policy_uri = policy_uri
          @jwks_uri = jwks_uri
          @jwks = jwks
          @software_id = software_id
          @software_version = software_version
        end

        def validate_scopes!(requested_scopes)
          allowed_scopes = @scope.nil? ? [] : @scope.split(" ")

          requested_scopes.each do |s|
            unless allowed_scopes.include?(s)
              raise Errors::InvalidScopeError, "Client was not registered with scope '#{s}'"
            end
          end
        end

        def valid_grant_type?(grant_type)
          @grant_types.include?(grant_type)
        end

        def valid_redirect_uri?(redirect_uri)
          @redirect_uris.include?(redirect_uri)
        end

        def multiple_redirect_uris?
          @redirect_uris.size > 1
        end
      end

      # Represents full OAuth 2.0 Dynamic Client Registration information (metadata + client details).
      # RFC 7591
      class OAuthClientInformationFull < OAuthClientMetadata
        attr_accessor :client_id,
          :client_secret,
          :client_id_issued_at,
          :client_secret_expires_at

        def initialize(
          client_id:,
          client_secret: nil,
          client_id_issued_at: nil,
          client_secret_expires_at: nil,
          **metadata_args
        )
          super(**metadata_args)
          @client_id = client_id
          @client_secret = client_secret
          @client_id_issued_at = client_id_issued_at
          @client_secret_expires_at = client_secret_expires_at
        end

        def authenticate!(request_client_id:, request_client_secret: nil)
          raise Errors::ClientAuthenticationError, "invalid client_id" if @client_id != request_client_id
          if @client_secret.nil?
            return
          end

          raise Errors::ClientAuthenticationError, "client_secret mismatch" if @client_secret != request_client_secret
          raise Errors::ClientAuthenticationError, "client_secret has expired" if secret_expired?
        end

        private

        def secret_expired?
          if @client_secret_expires_at.nil?
            return false
          end

          @client_secret_expires_at < Time.now.to_i
        end
      end

      # Represents OAuth 2.0 Authorization Server Metadata as defined in RFC 8414.
      # See https://datatracker.ietf.org/doc/html/rfc8414#section-2
      class OAuthMetadata
        attr_accessor :issuer,
          :authorization_endpoint,
          :token_endpoint,
          :registration_endpoint,
          :scopes_supported,
          :response_types_supported,
          :response_modes_supported,
          :grant_types_supported,
          :token_endpoint_auth_methods_supported,
          :token_endpoint_auth_signing_alg_values_supported,
          :service_documentation,
          :ui_locales_supported,
          :op_policy_uri,
          :op_tos_uri,
          :revocation_endpoint,
          :revocation_endpoint_auth_methods_supported,
          :revocation_endpoint_auth_signing_alg_values_supported,
          :introspection_endpoint,
          :introspection_endpoint_auth_methods_supported,
          :introspection_endpoint_auth_signing_alg_values_supported,
          :code_challenge_methods_supported

        # Default and supported values based on Python model
        DEFAULT_RESPONSE_TYPES_SUPPORTED = ["code"].freeze

        VALID_RESPONSE_TYPES_SUPPORTED = ["code"].freeze
        VALID_RESPONSE_MODES_SUPPORTED = ["query", "fragment"].freeze
        VALID_GRANT_TYPES_SUPPORTED = ["authorization_code", "refresh_token"].freeze
        VALID_TOKEN_ENDPOINT_AUTH_METHODS_SUPPORTED = ["none", "client_secret_post"].freeze
        VALID_REVOCATION_ENDPOINT_AUTH_METHODS_SUPPORTED = ["client_secret_post"].freeze
        VALID_INTROSPECTION_ENDPOINT_AUTH_METHODS_SUPPORTED = ["client_secret_post"].freeze
        VALID_CODE_CHALLENGE_METHODS_SUPPORTED = ["S256"].freeze

        def initialize(
          issuer:,
          authorization_endpoint: nil,
          token_endpoint: nil,
          registration_endpoint: nil,
          scopes_supported: nil,
          response_types_supported: DEFAULT_RESPONSE_TYPES_SUPPORTED.dup,
          response_modes_supported: nil,
          grant_types_supported: nil,
          token_endpoint_auth_methods_supported: nil,
          token_endpoint_auth_signing_alg_values_supported: nil,
          service_documentation: nil,
          ui_locales_supported: nil,
          op_policy_uri: nil,
          op_tos_uri: nil,
          revocation_endpoint: nil,
          revocation_endpoint_auth_methods_supported: nil,
          revocation_endpoint_auth_signing_alg_values_supported: nil,
          introspection_endpoint: nil,
          introspection_endpoint_auth_methods_supported: nil,
          introspection_endpoint_auth_signing_alg_values_supported: nil,
          code_challenge_methods_supported: nil
        )
          @issuer = issuer
          @authorization_endpoint = authorization_endpoint
          @token_endpoint = token_endpoint
          @registration_endpoint = registration_endpoint
          @scopes_supported = scopes_supported

          (response_types_supported || []).each do |rt|
            unless VALID_RESPONSE_TYPES_SUPPORTED.include?(rt)
              raise ArgumentError, "Invalid response_type_supported: #{rt}. Valid types are: #{VALID_RESPONSE_TYPES_SUPPORTED.join(", ")}"
            end
          end
          @response_types_supported = response_types_supported

          (response_modes_supported || []).each do |rm|
            unless VALID_RESPONSE_MODES_SUPPORTED.include?(rm)
              raise ArgumentError, "Invalid response_mode_supported: #{rm}. Valid modes are: #{VALID_RESPONSE_MODES_SUPPORTED.join(", ")}"
            end
          end
          @response_modes_supported = response_modes_supported

          (grant_types_supported || []).each do |gt|
            unless VALID_GRANT_TYPES_SUPPORTED.include?(gt)
              raise ArgumentError, "Invalid grant_type_supported: #{gt}. Valid types are: #{VALID_GRANT_TYPES_SUPPORTED.join(", ")}"
            end
          end
          @grant_types_supported = grant_types_supported

          (token_endpoint_auth_methods_supported || []).each do |team|
            unless VALID_TOKEN_ENDPOINT_AUTH_METHODS_SUPPORTED.include?(team)
              raise ArgumentError, "Invalid token_endpoint_auth_method_supported: #{team}. Valid methods are: #{VALID_TOKEN_ENDPOINT_AUTH_METHODS_SUPPORTED.join(", ")}"
            end
          end
          @token_endpoint_auth_methods_supported = token_endpoint_auth_methods_supported

          @token_endpoint_auth_signing_alg_values_supported = token_endpoint_auth_signing_alg_values_supported # Always nil in Python
          @service_documentation = service_documentation
          @ui_locales_supported = ui_locales_supported
          @op_policy_uri = op_policy_uri
          @op_tos_uri = op_tos_uri
          @revocation_endpoint = revocation_endpoint

          (revocation_endpoint_auth_methods_supported || []).each do |ream|
            unless VALID_REVOCATION_ENDPOINT_AUTH_METHODS_SUPPORTED.include?(ream)
              raise ArgumentError, "Invalid revocation_endpoint_auth_method_supported: #{ream}. Valid methods are: #{VALID_REVOCATION_ENDPOINT_AUTH_METHODS_SUPPORTED.join(", ")}"
            end
          end
          @revocation_endpoint_auth_methods_supported = revocation_endpoint_auth_methods_supported

          @revocation_endpoint_auth_signing_alg_values_supported = revocation_endpoint_auth_signing_alg_values_supported # Always nil in Python
          @introspection_endpoint = introspection_endpoint

          (introspection_endpoint_auth_methods_supported || []).each do |ieam|
            unless VALID_INTROSPECTION_AUTH_METHODS_SUPPORTED.include?(ieam) # Using VALID_INTROSPECTION_AUTH_METHODS
              raise ArgumentError, "Invalid introspection_endpoint_auth_method_supported: #{ieam}. Valid methods are: #{VALID_INTROSPECTION_AUTH_METHODS.join(", ")}"
            end
          end
          @introspection_endpoint_auth_methods_supported = introspection_endpoint_auth_methods_supported

          @introspection_endpoint_auth_signing_alg_values_supported = introspection_endpoint_auth_signing_alg_values_supported # Always nil in Python

          (code_challenge_methods_supported || []).each do |ccm|
            unless VALID_CODE_CHALLENGE_METHODS_SUPPORTED.include?(ccm)
              raise ArgumentError, "Invalid code_challenge_method_supported: #{ccm}. Valid methods are: #{VALID_CODE_CHALLENGE_METHODS_SUPPORTED.join(", ")}"
            end
          end
          @code_challenge_methods_supported = code_challenge_methods_supported
        end

        class << self
          DEFAULT_AUTHORIZE_PATH = "/authorize"
          DEFAULT_REGISTRATION_PATH = "/register"
          DEFAULT_TOKEN_PATH = "/token"

          def with_defaults(issuer_url:, client_registration_options:, **kwargs)
            metadata = OAuthMetadata.new(
              issuer: issuer_url,
              authorization_endpoint: issuer_url + DEFAULT_AUTHORIZE_PATH,
              token_endpoint: issuer_url + DEFAULT_TOKEN_PATH,
              scopes_supported: client_registration_options.valid_scopes,
              response_types_supported: ["code"],
              grant_types_supported: ["authorization_code", "refresh_token"],
              token_endpoint_auth_methods_supported: ["client_secret_post"],
              code_challenge_methods_supported: ["S256"],
              **kwargs,
            )

            if client_registration_options.enabled
              metadata.registration_endpoint = issuer_url + DEFAULT_REGISTRATION_PATH
            end

            metadata
          end
        end
      end
    end
  end
end
