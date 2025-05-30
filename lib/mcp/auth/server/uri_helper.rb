# frozen_string_literal: true

require "uri"

module MCP
  module Auth
    module Server
      module UriHelper
        # Constructs a redirect URI by adding parameters to a base URI.
        #
        # @param redirect_uri_base [String] The base URI.
        # @param params [Hash] Parameters to add to the URI query. Nil values are omitted.
        #                      Keys should be symbols or strings.
        # @return [String] The constructed URI string.
        def construct_redirect_uri(redirect_uri_base, **params)
          uri = URI.parse(redirect_uri_base)

          query_pairs = params.reject do |_, v|
            v.nil? || v.empty?
          end
          if uri.query && !uri.query.empty?
            query_pairs.concat(URI.decode_www_form(uri.query))
          end

          uri.query = query_pairs.any? ? URI.encode_www_form(query_pairs) : nil
          uri.to_s
        end
      end
    end
  end
end
