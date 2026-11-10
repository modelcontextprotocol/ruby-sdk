# frozen_string_literal: true

require "test_helper"
require "json"
require "rbconfig"
require "mcp/client/stdio"

module MCP
  class Client
    class StdioEnvironmentTest < Minitest::Test
      def test_default_environment_does_not_inherit_unrelated_variables
        with_environment("MCP_TEST_HOST_ONLY" => "host-value") do
          refute(server_environment.key?("MCP_TEST_HOST_ONLY"))
        end
      end

      def test_empty_env_does_not_inherit_unrelated_variables
        with_environment("MCP_TEST_HOST_ONLY" => "host-value") do
          refute(server_environment(env: {}).key?("MCP_TEST_HOST_ONLY"))
        end
      end

      def test_explicit_env_does_not_inherit_unrelated_variables
        with_environment("MCP_TEST_HOST_ONLY" => "host-value") do
          environment = server_environment(env: { "MCP_TEST_SERVER_SETTING" => "server-value" })

          assert_equal("server-value", environment["MCP_TEST_SERVER_SETTING"])
          refute(environment.key?("MCP_TEST_HOST_ONLY"))
        end
      end

      def test_default_environment_preserves_path_and_home
        home_variable = Gem.win_platform? ? "USERPROFILE" : "HOME"
        with_environment(home_variable => "server-home") do
          environment = server_environment

          assert_equal("server-home", environment[home_variable])
          assert_equal(ENV.fetch("PATH"), environment["PATH"])
        end
      end

      def test_default_environment_preserves_ruby_configuration
        variables = {
          "GEM_HOME" => Gem.dir,
          "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR),
        }
        with_environment(variables) do
          assert_equal(variables, server_environment.slice(*variables.keys))
        end
      end

      def test_default_environment_does_not_inherit_bundle_gemfile
        with_environment("BUNDLE_GEMFILE" => File.expand_path("client/Gemfile")) do
          refute(server_environment.key?("BUNDLE_GEMFILE"))
        end
      end

      def test_explicit_env_can_select_bundle_gemfile
        gemfile = File.expand_path("server/Gemfile")
        with_environment("BUNDLE_GEMFILE" => File.expand_path("client/Gemfile")) do
          environment = server_environment(env: { "BUNDLE_GEMFILE" => gemfile })

          assert_equal(gemfile, environment["BUNDLE_GEMFILE"])
        end
      end

      def test_default_environment_preserves_case_insensitive_variable_lookups
        # Windows retains mixed-case names in ENV.to_h but accepts uppercase ENV lookups.
        environment = Hash.new { |hash, key| hash.find { |name, _| name.casecmp?(key) }&.last }
        environment["Path"] = "server-path"
        Stdio.const_set(:ENV, environment)

        assert_equal("server-path", server_environment["PATH"])
      ensure
        Stdio.send(:remove_const, :ENV)
      end

      def test_explicit_env_overrides_default_variables
        environment = server_environment(env: { "PATH" => "server-path" })

        assert_equal("server-path", environment["PATH"])
      end

      def test_explicit_nil_removes_a_default_variable
        with_environment("PATH" => "parent-path") do
          refute(server_environment(env: { "PATH" => nil }).key?("PATH"))
        end
      end

      def test_missing_default_variable_is_not_added
        with_environment("TERM" => nil) do
          refute(server_environment.key?("TERM"))
        end
      end

      def test_inherit_env_restores_full_environment_inheritance
        with_environment("MCP_TEST_HOST_ONLY" => "host-value") do
          environment = server_environment(inherit_env: true)

          assert_equal("host-value", environment["MCP_TEST_HOST_ONLY"])
        end
      end

      def test_explicit_env_overrides_and_removes_variables_when_inheriting
        with_environment("MCP_TEST_HOST_ONLY" => "host-value", "MCP_TEST_REMOVE" => "remove-value") do
          environment = server_environment(
            inherit_env: true,
            env: { "MCP_TEST_HOST_ONLY" => "server-value", "MCP_TEST_REMOVE" => nil },
          )

          assert_equal("server-value", environment["MCP_TEST_HOST_ONLY"])
          refute(environment.key?("MCP_TEST_REMOVE"))
        end
      end

      private

      def server_environment(**options)
        transport = Stdio.new(
          command: RbConfig.ruby,
          args: ["-e", "require 'json'; puts JSON.generate(ENV.to_h)"],
          **options,
        )
        transport.start
        output = Timeout.timeout(5) { transport.instance_variable_get(:@stdout).read }
        JSON.parse(output)
      ensure
        transport&.close
      end

      def with_environment(variables)
        previous_values = variables.to_h { |key, _| [key, ENV[key]] }
        variables.each { |key, value| ENV[key] = value }
        yield
      ensure
        previous_values.each { |key, value| ENV[key] = value }
      end
    end
  end
end
