# frozen_string_literal: true

source "https://rubygems.org"

# Specify runtime dependencies in the gemspec
gemspec

# Specify development dependencies below
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false
gem "rubocop-shopify", ">= 2.18", require: false if RUBY_VERSION >= "3.1"

gem "puma", ">= 5.0.0"
gem "rackup", ">= 2.1.0"

gem "activesupport"
# Fix io-console install error when Ruby 3.0.
gem "debug" if RUBY_VERSION >= "3.1"
gem "rake", "~> 13.0"
gem "sorbet-static-and-runtime" if RUBY_VERSION >= "3.0"
gem "yard", "~> 0.9"
gem "yard-sorbet", "~> 0.9" if RUBY_VERSION >= "3.1"

group :test do
  gem "faraday", ">= 2.0"
  gem "minitest", "~> 5.1", require: false
  gem "mocha"
  gem "webmock"
end
