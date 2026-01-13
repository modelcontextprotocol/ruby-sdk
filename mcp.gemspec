# frozen_string_literal: true

require_relative "lib/mcp/version"

Gem::Specification.new do |spec|
  spec.name          = "mcp"
  spec.version       = MCP::VERSION
  spec.authors       = ["Model Context Protocol"]
  spec.email         = ["mcp-support@anthropic.com"]

  spec.summary       = "The official Ruby SDK for Model Context Protocol servers and clients"
  spec.description   = spec.summary
  spec.homepage      = "https://github.com/modelcontextprotocol/ruby-sdk"
  spec.license       = "Apache-2.0"

  # Since this library is used by a broad range of users, it does not align its support policy with Ruby's EOL.
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["changelog_uri"] = "https://github.com/modelcontextprotocol/ruby-sdk/releases/tag/v#{spec.version}"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/mcp"

  spec.files = Dir.chdir(File.expand_path("..", __FILE__)) do
    %x(git ls-files -z).split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency("json-schema", ">= 4.1")
end
