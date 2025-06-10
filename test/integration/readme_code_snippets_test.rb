# frozen_string_literal: true

require "test_helper"

require "fileutils"
require "open3"
require "tempfile"
require "timeout"

require "readme_test_helper"

# Run tests on the code snippets in the README.md file to ensure they work as expected.
# These are not intended to be comprehensive; they are just sanity checks.
class ReadmeCodeSnippetsTest < ActiveSupport::TestCase
  include ReadmeTestHelper

  make_my_diffs_pretty!

  test "Rails Controller example handles requests" do
    assert_json_lines(
      [
        { jsonrpc: "2.0", id: "1", result: {} },
      ],
      run_code_snippet("rails_controller"),
    )
  end

  test "Stdio Transport example works exactly as documented in README" do
    # This snippet is a standalone example server/transport, so we run it directly and send it requests
    stdout = Tempfile.create(["stdio_transport", ".rb"]) do |file|
      file.write(extract_readme_code_snippet("stdio_transport"))
      file.close
      FileUtils.chmod("+x", file.path) # Make executable

      # Reuse example input from README, but drop command to start the server (`$ ...` line)
      stdin_data = extract_readme_code_snippet("running_stdio_server", language: "console").lines(chomp: true).grep_v(/^\$\s/).join("\n")

      stdout, stderr, status = Open3.capture3(file.path, stdin_data:)
      assert_predicate(status, :success?, "Expected #{file.path} to exit with success, but got exit status #{status.exitstatus}\n\nSTDOUT: #{stdout}\n\nSTDERR: #{stderr}")
      assert_empty(stderr, "Expected no stderr in: #{stderr}")
      refute_empty(stdout, "Expected stdout not to be empty")

      stdout
    end

    assert_json_lines(
      [
        { jsonrpc: "2.0", id: "1", result: {} },
        {
          jsonrpc: "2.0",
          id: "2",
          result: {
            tools: [
              {
                name: "example_tool",
                description: "A simple example tool that echoes back its arguments",
                inputSchema: { type: "object", properties: { message: { type: "string" } }, required: ["message"] },
              },
            ],
          },
        },
      ],
      stdout,
    )
  end

  test "Configuration example works exactly as documented in README" do
    stdout = run_code_snippet("configuration")

    request = {
      jsonrpc: "2.0",
      id: "1",
      method: "tools/call",
      params: { name: "error_tool", arguments: {} },
    }.to_json

    error = MCP::Server::RequestHandlerError.new("Internal error calling tool error_tool", request)
    metadata = { model_context_protocol: { request: } }
    instrumentation_data = { method: "tools/call", tool_name: "error_tool", error: :internal_error, duration: 1.23 }

    response = {
      jsonrpc: "2.0",
      id: "1",
      error: { code: -32603, message: "Internal error", data: "Internal error calling tool error_tool" },
    }.to_json

    assert_equal(<<~STDOUT, stdout)
      Bugsnag notified of #{error.inspect} with metadata #{metadata.inspect}
      Got instrumentation data #{instrumentation_data}
      #{response}
    STDOUT
  end

  test "Per-Server Configuration example works exactly as documented in README" do
    stdout = run_code_snippet("per_server_configuration")

    request = {
      jsonrpc: "2.0",
      id: "1",
      method: "tools/call",
      params: { name: "error_tool", arguments: {} },
    }.to_json

    error = MCP::Server::RequestHandlerError.new("Internal error calling tool error_tool", request)
    metadata = { model_context_protocol: { request: } }
    instrumentation_data = { method: "tools/call", tool_name: "error_tool", error: :internal_error, duration: 1.23 }

    response = {
      jsonrpc: "2.0",
      id: "1",
      error: { code: -32603, message: "Internal error", data: "Internal error calling tool error_tool" },
    }.to_json

    expected_output = <<~OUTPUT
      Bugsnag notified of #{error.inspect} with metadata #{metadata.inspect}
      Got instrumentation data #{instrumentation_data}
      #{response}
    OUTPUT

    assert_equal(expected_output, stdout)
  end

  test "Server Context example works exactly as documented in README" do
    assert_json_lines(
      [
        { user_id: 123, request_id: "...uuid..." },
      ],
      run_code_snippet("server_context"),
    )
  end

  test "Instrumentation Callback example works exactly as documented in README" do
    instrumentation_data = { example: "data" }

    assert_equal(<<~STDOUT, run_code_snippet("instrumentation_callback"))
      Instrumentation: #{instrumentation_data}
    STDOUT
  end

  test "Protocol Version example works exactly as documented in README" do
    assert_equal("2024-11-05",                                 run_code_snippet("set_server_protocol_version").chomp)
    assert_equal(MCP::Configuration::DEFAULT_PROTOCOL_VERSION, run_code_snippet("unset_server_protocol_version").chomp)
  end

  test "Tools examples work exactly as documented in README" do
    assert_json_lines(
      [
        { jsonrpc: "2.0", id: "1", result: { content: [{ type: "text", text: "OK" }], isError: false } },
      ],
      run_code_snippet("tool_class_definition"),
    )

    skip "FIXME: this next code snippet is invalid and there doesn't seem to be a way to make both pass..."

    assert_json_lines(
      [
        { jsonrpc: "2.0", id: "1", result: { content: [{ type: "text", text: "OK" }], isError: false } },
      ],
      run_code_snippet("tool_definition_with_block"),
    )
  end

  test "Prompts examples work exactly as documented in README" do
    assert_json_lines(
      [
        {
          jsonrpc: "2.0",
          id: "1",
          result: {
            prompts: [
              {
                name: "my_prompt",
                description: "This prompt performs specific functionality...",
                arguments: [
                  { name: "message", description: "Input message", required: true },
                ],
              },
            ],
          },
        },
        {
          jsonrpc: "2.0",
          id: "2",
          result: {
            description: "Response description",
            messages: [
              { role: "user",      content: { type: "text", text: "User message" } },
              { role: "assistant", content: { type: "text", text: "Test message" } },
            ],
          },
        },
      ],
      run_code_snippet("prompt_class_definition"),
    )

    assert_json_lines(
      [
        {
          jsonrpc: "2.0",
          id: "1",
          result: {
            prompts: [
              {
                name: "my_prompt",
                description: "This prompt performs specific functionality...",
                arguments: [
                  { name: "message", description: "Input message", required: true },
                ],
              },
            ],
          },
        },
        {
          jsonrpc: "2.0",
          id: "2",
          result: {
            description: "Response description",
            messages: [
              { role: "user",      content: { type: "text", text: "User message" } },
              { role: "assistant", content: { type: "text", text: "Test message" } },
            ],
          },
        },
      ],
      run_code_snippet("prompt_definition_with_block"),
    )
  end

  test "Prompt usage example works exactly as documented in README" do
    assert_json_lines(
      [
        {
          jsonrpc: "2.0",
          id: "1",
          result: {
            description: "Response with user context",
            messages: [
              { role: "user", content: { type: "text", text: "User ID: 123" } },
            ],
          },
        },
      ],
      run_code_snippet("prompts_usage"),
    )
  end

  test "Prompts Instrumentation Callback example works exactly as documented in README" do
    stdout = run_code_snippet("prompts_instrumentation_callback")
    instrumentation_data = { method: "ping", duration: 1.23 }

    assert_equal(<<~STDOUT, stdout)
      Got instrumentation data #{instrumentation_data}
      #{{ jsonrpc: "2.0", id: "1", result: {} }.to_json}
    STDOUT
  end

  test "Resources examples work exactly as documented in README" do
    assert_json_lines(
      [
        {
          jsonrpc: "2.0",
          id: "1",
          result: {
            resources: [
              {
                uri: "https://example.com/my_resource",
                name: "My Resource",
                description: "Lorem ipsum dolor sit amet",
                mimeType: "text/html",
              },
            ],
          },
        },
      ],
      run_code_snippet("resources"),
    )
  end

  test "Resources Read Handler example works exactly as documented in README" do
    assert_json_lines(
      [
        {
          jsonrpc: "2.0",
          id: "1",
          result: {
            contents: [
              {
                uri: "https://example.com/test_resource",
                mimeType: "text/plain",
                text: "https://example.com/test_resource",
              },
            ],
          },
        },
      ],
      run_code_snippet("resources_read_handler"),
    )
  end

  private

  def assert_json_lines(expected, actual, message = "Expected the given JSON lines")
    assert_equal(
      expected,
      actual.lines(chomp: true).map { JSON.parse(_1, symbolize_names: true) },
      message,
    )
  end

  def run_code_snippet(code_snippet_name)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write("code_snippet.rb", extract_readme_code_snippet(code_snippet_name))
        File.write("test.rb", file_fixture("code_snippet_wrappers/readme/#{code_snippet_name}.rb").read)

        stdout, stderr, status = Timeout.timeout(5) { Open3.capture3("ruby", "test.rb") }
        assert_predicate(status, :success?, "Expected test.rb to exit with success, but got exit status #{status.exitstatus}\n\nSTDOUT: #{stdout}\n\nSTDERR: #{stderr}")
        assert_empty(stderr, "Expected no stderr in: #{stderr}")
        refute_empty(stdout, "Expected stdout not to be empty")

        normalize_stdout(stdout)
      end
    end
  end

  def normalize_stdout(stdout)
    stdout
      .gsub(/\d+\.\d{10,}(?:e-\d+)?/, "1.23") # Normalize long floats e.g. 'duration: 1.23456789012345678-05' => 'duration: 1.23'
  end
end
