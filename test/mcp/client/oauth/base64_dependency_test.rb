# frozen_string_literal: true

require "test_helper"
require "open3"

module MCP
  class Client
    module OAuth
      class Base64DependencyTest < ActiveSupport::TestCase
        # `base64` stopped being a default gem in Ruby 3.4 and the gemspec does not declare it, so under Bundler
        # an application that does not happen to get it from another gem cannot load it. Checked in a fresh process,
        # since this one has loaded it for the tests already, with the library refused the way Bundler refuses it.
        test "the client and the server-side OAuth classes load and encode without the base64 library" do
          lib = File.expand_path("../../../../lib", __dir__)
          script = <<~'RUBY'
            module RefuseBase64
              def require(name)
                raise LoadError, "cannot load such file -- base64" if name == "base64"

                super
              end
            end
            Object.prepend(RefuseBase64)

            require "mcp"
            MCP::Client
            pair = MCP::Client::OAuth::PKCE.generate
            abort("unexpected code_challenge: #{pair[:code_challenge]}") unless pair[:code_challenge].match?(/\A[A-Za-z0-9_-]{43}\z/)
            MCP::Client::OAuth::JWTClientAssertion
            MCP::Server::OAuth::ProtectedResourceMetadata.new(
              resource: "http://localhost:3000/mcp", authorization_servers: ["http://localhost:3000"],
            )
            abort("base64 was loaded") if defined?(Base64)
          RUBY
          _stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil }, RbConfig.ruby, "-I", lib, "-e", script)

          assert_predicate status, :success?, stderr
        end
      end
    end
  end
end
