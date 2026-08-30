# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.ruby_opts = ["-W0", "-W:deprecated"]
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: [:rubocop, :test, "conformance:test"]

namespace :conformance do
  desc "Run MCP conformance tests (PORT, SCENARIO, SPEC_VERSION, VERBOSE)"
  task :test do |t|
    next unless npx_available?(t.name)

    require_relative "conformance/server_runner"
    require_relative "conformance/client_runner"

    options = {}
    options[:port] = Integer(ENV["PORT"]) if ENV["PORT"]
    options[:scenario] = ENV["SCENARIO"] if ENV["SCENARIO"]
    options[:spec_version] = ENV["SPEC_VERSION"] if ENV["SPEC_VERSION"]
    options[:verbose] = true if ENV["VERBOSE"]

    Conformance::ServerRunner.new(**options).run
    Conformance::ClientRunner.new(**options.reject { |key, _value| key == :port }).run
  end

  desc "List available conformance scenarios"
  task :list do |t|
    next unless npx_available?(t.name)

    system("npx", "--yes", "@modelcontextprotocol/conformance", "list", "--server")
    system("npx", "--yes", "@modelcontextprotocol/conformance", "list", "--client")
  end

  desc "Start the conformance server (PORT)"
  task :server do
    require_relative "conformance/server"

    options = {}
    options[:port] = Integer(ENV["PORT"]) if ENV["PORT"]

    Conformance::Server.new(**options).start
  end
end

# The other two former names now fail with a "Did you mean?" suggestion, but a bare `conformance`
# would match the `conformance/` directory: Rake synthesizes a file task for it and exits 0 without
# running anything. This keeps the name pointing at the suite instead of at that silent no-op.
desc "Alias for conformance:test"
task conformance: "conformance:test"

namespace :docs do
  desc "Serve the documentation site locally at http://localhost:4000 (PORT)"
  task :preview do
    docs_dir = File.expand_path("docs", __dir__)
    generate_docs_versions_data(docs_dir)

    env = {
      "BUNDLE_GEMFILE" => File.join(docs_dir, "Gemfile"),
      "RUBYOPT" => "-r#{File.join(docs_dir, "_preview", "taint_shim.rb")}",
    }
    port = ENV.fetch("PORT", "4000")

    Bundler.with_unbundled_env do
      system(env, "bundle", "install", "--quiet", chdir: docs_dir, exception: true)
      system(env, "bundle", "exec", "jekyll", "serve", "--port", port, chdir: docs_dir, exception: true)
    rescue Interrupt
      # Ctrl-C is the way to stop the preview, not an error.
    end
  end
end

# Mirrors bin/generate-gh-pages.sh: the released site receives `_data/versions.yml` from
# the version tags at deploy time, and the preview generates the same data so the nav footer
# shows the released-gem version line.
def generate_docs_versions_data(docs_dir)
  versions = %x(git tag --list).split("\n").filter_map { |tag|
    tag[/\A[^0-9]*(\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?)\z/, 1]
  }.sort_by { |version|
    Gem::Version.new(version)
  }.reverse
  return if versions.empty?

  mkdir_p(File.join(docs_dir, "_data"))
  File.write(File.join(docs_dir, "_data", "versions.yml"), versions.map { |version| "- #{version}\n" }.join)
end

def npx_available?(task_name)
  return true if system("which", "npx", out: File::NULL, err: File::NULL)

  warn("Skipping #{task_name}: npx is not installed. Install Node.js to run this task: https://nodejs.org/")
  false
end
