# frozen_string_literal: true

require "test_helper"

require "open3"
require "json"
require "timeout"
require "tempfile"
require "fileutils"

require "readme_test_helper"

# Run tests on the files in the `examples` directory to ensure they work as expected.
# These are not intended to be comprehensive; they are just sanity checks.
class ExamplesTest < ActiveSupport::TestCase
  include ReadmeTestHelper

  make_my_diffs_pretty!

  test "examples/stdio_server.rb example works exactly as documented in README" do
    command_line, *input_lines = extract_readme_code_snippet("running_stdio_server", language: "console").lines(chomp: true)

    command = command_line.delete_prefix("$ ")
    stdin_data = input_lines.join("\n")

    stdout, stderr, status = Open3.capture3(command, chdir: project_root, stdin_data:)
    assert_predicate(status, :success?, "Expected #{command} to exit with success, but got exit status #{status.exitstatus}\n\nSTDOUT: #{stdout}\n\nSTDERR: #{stderr}")
    assert_empty(stderr, "Expected no stderr in: #{stderr}")
    refute_empty(stdout, "Expected stdout not to be empty")

    assert_equal(
      [
        { jsonrpc: "2.0", id: "1", result: {} },
        {
          jsonrpc: "2.0",
          id: "2",
          result: {
            tools: [
              {
                name: "example_tool",
                description: "A simple example tool that adds two numbers",
                inputSchema: { type: "object", properties: { a: { type: "number" }, b: { type: "number" } }, required: ["a", "b"] },
              },
              {
                name: "echo",
                description: "A simple example tool that echoes back its arguments",
                inputSchema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
              },
            ],
          },
        },
      ],
      stdout.lines.map { |line| JSON.parse(line, symbolize_names: true) },
    )
  end
end
