# MCP Conformance Tests

Validates the Ruby SDK's conformance to the MCP specification using [`@modelcontextprotocol/conformance`](https://github.com/modelcontextprotocol/conformance).

## Prerequisites

- Node.js (for `npx`)
- `bundle install` completed

## Server Conformance

### Run all scenarios

```bash
bundle exec rake conformance
```

Starts the conformance server, runs all active scenarios against it, prints a pass/fail
summary for each scenario, and exits with a non-zero status code if any unexpected failures
are detected. Scenarios listed in `expected_failures.yml` are allowed to fail without
affecting the exit code.

### Environment variables

| Variable       | Description                          | Default |
|----------------|--------------------------------------|---------|
| `PORT`         | Server port                          | `9292`  |
| `SCENARIO`     | Run a single scenario by name        | (all)   |
| `SPEC_VERSION` | Filter scenarios by spec version     | (all)   |
| `VERBOSE`      | Show raw JSON output when set        | (off)   |

```bash
# Run a single scenario
bundle exec rake conformance SCENARIO=ping

# Use a different port with verbose output
bundle exec rake conformance PORT=3000 VERBOSE=1

# Start the server on a specific port
bundle exec rake conformance_server PORT=3000
```

### Start the server and test separately

```bash
# Terminal 1: start the server
bundle exec rake conformance_server

# Terminal 2: run all scenarios
npx @modelcontextprotocol/conformance server --url http://localhost:9292/mcp

# Terminal 2: run a single scenario
npx @modelcontextprotocol/conformance server --url http://localhost:9292/mcp --scenario ping
```

Keeps the server alive between test runs, which avoids the startup overhead when iterating
on a single scenario. Stop the server with Ctrl+C when done.

### List available scenarios

```bash
bundle exec rake conformance_list
```

Prints all scenario names that can be passed to `SCENARIO`.

## Client Conformance

The client conformance tests validate `MCP::Client` against the MCP specification by running
it through scenarios served by the conformance test runner.

### Run all client scenarios

```bash
npx @modelcontextprotocol/conformance client --suite core --command "ruby conformance/client.rb"
```

### Run a single scenario

```bash
npx @modelcontextprotocol/conformance client --scenario initialize --command "ruby conformance/client.rb"
```

### List available client scenarios

```bash
npx @modelcontextprotocol/conformance list --client
```

The conformance runner starts a test server for each scenario, sets the
`MCP_CONFORMANCE_SCENARIO` environment variable, and invokes the command with the server URL
as the first argument.

## SDK Tier Report

The [MCP SDK Tier system](https://modelcontextprotocol.io/community/sdk-tiers) requires SDK
maintainers to self-assess and report results to the SDK Working Group via
[modelcontextprotocol/modelcontextprotocol issues](https://github.com/modelcontextprotocol/modelcontextprotocol/issues).

To generate a full tier assessment report, use the `/mcp-sdk-tier-audit` slash command from
the [modelcontextprotocol/conformance](https://github.com/modelcontextprotocol/conformance)
repository with the conformance server running:

```bash
# Terminal 1 (this repository): start the conformance server
bundle exec rake conformance_server

# Terminal 2 (conformance repository): run the tier audit skill as a slash command in Claude Code
/mcp-sdk-tier-audit /path/to/modelcontextprotocol/ruby-sdk http://localhost:9292/mcp
```

The skill evaluates conformance pass rate, issue label taxonomy, triage metrics, documentation
coverage, and policy compliance, then produces a markdown report suitable for tier advancement
submissions.

## File Structure

```
conformance/
  server.rb              # Conformance server (Rack + Puma, default port 9292)
  runner.rb              # Starts the server, runs npx conformance, exits with result code
  client.rb              # Conformance client for client-side scenario testing
  expected_failures.yml  # Baseline of known-failing scenarios
  README.md              # This file
```

## Known Limitations

Known-failing scenarios are registered in `conformance/expected_failures.yml`. They are allowed to
fail without affecting the exit code and are tracked to catch regressions.
These are shown in the output of `bundle exec rake conformance`.
