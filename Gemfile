# frozen_string_literal: true

# Dependencies for the local docs preview (`rake docs:preview`), kept out of the gem's own Gemfile:
# github-pages mirrors the GitHub Pages runtime that builds the released site
# (jekyll-remote-theme, jekyll-redirect-from, and the Jekyll version Pages actually runs).
source "https://rubygems.org"

gem "github-pages", group: :jekyll_plugins
gem "webrick"

# Former default gems that the Jekyll version pinned by github-pages still requires on Ruby 4.0.
gem "base64"
gem "bigdecimal"
gem "csv"
gem "logger"
