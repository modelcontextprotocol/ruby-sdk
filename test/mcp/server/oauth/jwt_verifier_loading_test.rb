# frozen_string_literal: true

require "test_helper"
require "open3"

module MCP
  class Server
    module OAuth
      class JWTVerifierLoadingTest < Minitest::Test
        def test_rejects_an_older_jwt_already_loaded
          ["2.10.2", "3.2.0"].each do |version|
            script = <<~RUBY
              require "mcp"
              require "jwt"
              loaded = Gem.loaded_specs.fetch("jwt").dup
              loaded.version = Gem::Version.new(#{version.inspect})
              Gem.loaded_specs["jwt"] = loaded
              MCP::Server::OAuth::JWTVerifier
            RUBY
            _stdout, stderr, status = run_ruby(script)

            refute_predicate(status, :success?, version)
            assert_includes(stderr, "LoadError")
            assert_includes(stderr, "gem 'jwt', '>= 3.3.0'")
          end
        end

        def test_loads_with_a_supported_jwt
          _stdout, stderr, status = run_ruby('require "mcp"; MCP::Server::OAuth::JWTVerifier')

          assert_predicate(status, :success?, stderr)
        end

        def test_other_verifiers_do_not_load_jwt
          script = <<~RUBY
            require "mcp"
            MCP::Server::OAuth::IntrospectionVerifier
            abort "jwt was loaded" if Gem.loaded_specs.key?("jwt")
          RUBY
          _stdout, stderr, status = run_ruby(script)

          assert_predicate(status, :success?, stderr)
        end

        private

        def run_ruby(script)
          lib = File.expand_path("../../../../lib", __dir__)
          # Keep bundled gems available without either Bundler startup hook.
          env = { "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR) }
          Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script)
        end
      end
    end
  end
end
