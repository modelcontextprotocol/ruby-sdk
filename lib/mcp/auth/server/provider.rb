# frozen_string_literal: true

require_relative "../models"

module MCP
  module Auth
    module Server
      class AuthorizationParams
        attr_accessor :client_id,
          :state,
          :scopes,
          :code_challenge,
          :redirect_uri,
          :redirect_uri_provided_explicitly,
          :response_type

        def initialize(
          client_id:,
          code_challenge:,
          redirect_uri:,
          redirect_uri_provided_explicitly:,
          response_type:,
          state: nil,
          scopes: nil
        )
          @client_id = client_id
          @state = state
          @scopes = scopes
          @code_challenge = code_challenge
          @response_type = response_type
          @redirect_uri = redirect_uri
          @redirect_uri_provided_explicitly = redirect_uri_provided_explicitly
        end
      end

      class AuthorizationCode
        attr_accessor :code,
          :scopes,
          :expires_at,
          :client_id,
          :code_challenge,
          :redirect_uri,
          :redirect_uri_provided_explicitly

        def initialize(
          code:,
          scopes:,
          expires_at:,
          client_id:,
          code_challenge:,
          redirect_uri:,
          redirect_uri_provided_explicitly:
        )
          @code = code
          @scopes = scopes
          @expires_at = expires_at
          @client_id = client_id
          @code_challenge = code_challenge
          @redirect_uri = redirect_uri
          @redirect_uri_provided_explicitly = redirect_uri_provided_explicitly
        end

        def belongs_to_client?(client_id)
          @client_id == client_id
        end

        def expired?
          @expires_at < Time.now.to_i
        end

        def code_challenge_match?(other)
          @code_challenge == other
        end
      end

      class RefreshToken
        attr_accessor :token,
          :client_id,
          :scopes,
          :expires_at

        def initialize(
          token:,
          client_id:,
          scopes:,
          expires_at: nil
        )
          @token = token
          @client_id = client_id
          @scopes = scopes
          @expires_at = expires_at
        end
      end

      class AccessToken
        attr_accessor :token,
          :client_id,
          :scopes,
          :expires_at

        def initialize(
          token:,
          client_id:,
          scopes:,
          expires_at: nil
        )
          @token = token
          @client_id = client_id
          @scopes = scopes
          @expires_at = expires_at
        end
      end

      module OAuthAuthorizationServerProvider
        # Returns the OAuth metadata for this authorization server.
        # See https://datatracker.ietf.org/doc/html/rfc8414#section-2
        #
        # @return [MCP::Auth::Models::OAuthMetadata] The OAuth metadata for this server.
        def oauth_metadata
          raise NotImplementedError, "#{self.class.name}#oauth_metadata is not implemented"
        end

        def client_registration_options
          raise NotImplementedError, "#{self.class.name}#client_registration_options is not implemented"
        end

        # Retrieves client information by client ID.
        # Implementors MAY raise NotImplementedError if dynamic client registration is
        # disabled in ClientRegistrationOptions.
        #
        # @param client_id [String] The ID of the client to retrieve.
        # @return [MCP::Auth::Models::OAuthClientInformationFull, nil] The client information, or nil if the client does not exist.
        def get_client(client_id)
          raise NotImplementedError, "#{self.class.name}#get_client is not implemented"
        end

        # Saves client information as part of registering it.
        # Implementors MAY raise NotImplementedError if dynamic client registration is
        # disabled in ClientRegistrationOptions.
        #
        # @param client_info [MCP::Auth::Models::OAuthClientInformationFull] The client metadata to register.
        # @raise [MCP::Auth::Errors::RegistrationError] If the client metadata is invalid.
        def register_client(client_info)
          raise NotImplementedError, "#{self.class.name}#register_client is not implemented"
        end

        # Called as part of the /authorize endpoint, and returns a URL that the client
        # will be redirected to.
        # Many MCP implementations will redirect to a third-party provider to perform
        # a second OAuth exchange with that provider. In this sort of setup, the client
        # has an OAuth connection with the MCP server, and the MCP server has an OAuth
        # connection with the 3rd-party provider. At the end of this flow, the client
        # should be redirected to the redirect_uri from params.redirect_uri.
        #
        # +--------+     +------------+     +-------------------+
        # |        |     |            |     |                   |
        # | Client | --> | MCP Server | --> | 3rd Party OAuth   |
        # |        |     |            |     | Server            |
        # +--------+     +------------+     +-------------------+
        #                     |   ^                  |
        # +------------+      |   |                  |
        # |            |      |   |    Redirect      |
        # |redirect_uri|<-----+   +------------------+
        # |            |
        # +------------+
        #
        # Implementations will need to define another handler on the MCP server return
        # flow to perform the second redirect, and generate and store an authorization
        # code as part of completing the OAuth authorization step.
        #
        # Implementations SHOULD generate an authorization code with at least 160 bits of
        # entropy, and MUST generate an authorization code with at least 128 bits of entropy.
        # See https://datatracker.ietf.org/doc/html/rfc6749#section-10.10.
        #
        # @param auth_params      [MCP::Auth::Server::AuthorizationParams] The parameters of the authorization request.
        # @return [String] A URL to redirect the client to for authorization.
        # @raise [MCP::Auth::Errors::AuthorizeError] If the authorization request is invalid.
        def authorize(auth_params)
          raise NotImplementedError, "#{self.class.name}#authorize is not implemented"
        end

        # Handles the callback from the OAuth provider after the user has authorized
        # the application. This is called when the OAuth provider redirects back to
        # the MCP server's callback endpoint.
        #
        # Implementations should validate the code and state parameters, exchange the
        # authorization code with the OAuth provider if needed, and return a URL to
        # redirect the user back to the original client application.
        #
        # @param code [String] The authorization code from the OAuth provider
        # @param state [String] The state parameter that was passed to the authorize endpoint
        # @return [String] The URL to redirect the user to (typically the client's redirect_uri)
        # @raise [MCP::Auth::Errors::AuthorizeError] If the callback parameters are invalid
        def authorize_callback(code:, state:)
          raise NotImplementedError, "#{self.class.name}#handle_callback is not implemented"
        end

        # Loads an AuthorizationCode by its code string.
        #
        # @param authorization_code [String] The authorization code string to load.
        # @return [MCP::Auth::Server::AuthorizationCode, nil] The AuthorizationCode object, or nil if not found.
        def load_authorization_code(authorization_code)
          raise NotImplementedError, "#{self.class.name}#load_authorization_code is not implemented"
        end

        # Exchanges an authorization code for an access token and refresh token.
        #
        # @param client [MCP::Auth::Models::OAuthClientInformationFull] The client exchanging the authorization code.
        # @param authorization_code [MCP::Auth::Server::AuthorizationCode] The authorization code object to exchange.
        # @return [MCP::Auth::Models::OAuthToken] The OAuth token, containing access and refresh tokens.
        # @raise [Mcp::Auth::Server::TokenError] If the request is invalid.
        def exchange_authorization_code(client, authorization_code)
          raise NotImplementedError, "#{self.class.name}#exchange_authorization_code is not implemented"
        end

        # Loads a RefreshToken by its token string.
        #
        # @param client [Mcp::Shared::Auth::OAuthClientInformationFull] The client that is requesting to load the refresh token.
        # @param refresh_token_str [String] The refresh token string to load.
        # @return [Mcp::Auth::Server::RefreshToken, nil] The RefreshToken object if found, or nil if not found.
        def load_refresh_token(client, refresh_token)
          raise NotImplementedError, "#{self.class.name}#load_refresh_token is not implemented"
        end

        # Exchanges a refresh token for an access token and (potentially new) refresh token.
        # Implementations SHOULD rotate both the access token and refresh token.
        #
        # @param client [Mcp::Shared::Auth::OAuthClientInformationFull] The client exchanging the refresh token.
        # @param refresh_token [Mcp::Auth::Server::RefreshToken] The refresh token object to exchange.
        # @param scopes [Array<String>] Optional scopes to request with the new access token.
        # @return [Mcp::Shared::Auth::OAuthToken] The OAuth token, containing access and refresh tokens.
        # @raise [Mcp::Auth::Server::TokenError] If the request is invalid.
        def exchange_refresh_token(client, refresh_token, scopes)
          raise NotImplementedError, "#{self.class.name}#exchange_refresh_token is not implemented"
        end

        # Loads an access token by its token string.
        #
        # @param token_str [String] The access token string to verify.
        # @return [Mcp::Auth::Server::AccessToken, nil] The AccessToken object, or nil if the token is invalid.
        def load_access_token(token_str)
          raise NotImplementedError, "#{self.class.name}#load_access_token is not implemented"
        end

        # Revokes an access or refresh token.
        # If the given token is invalid or already revoked, this method should do nothing.
        # Implementations SHOULD revoke both the access token and its corresponding
        # refresh token, regardless of which of the access token or refresh token is provided.
        #
        # @param token [Mcp::Auth::Server::AccessToken, Mcp::Auth::Server::RefreshToken] The token object to revoke.
        # @return [void]
        def revoke_token(token)
          raise NotImplementedError, "#{self.class.name}#revoke_token is not implemented"
        end
      end
    end
  end
end
