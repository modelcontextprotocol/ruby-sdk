---
layout: default
title: Installation
nav_order: 2
permalink: /installation/
redirect_from:
  - /installation.html
---

# Installation

Install the gem and any optional dependencies for the features you use.

## Requirements

Ruby 2.7.0 or later.

## Installing the Gem

Add this line to your application's Gemfile:

```ruby
gem "mcp"
```

And then execute:

```console
$ bundle install
```

Or install it yourself as:

```console
$ gem install mcp
```

You may need to add additional dependencies depending on which features you wish to access. For example, the HTTP client transport requires the `faraday` gem:

```ruby
gem "faraday", ">= 2.0"
```

Reading SSE (`text/event-stream`) responses needs `event_stream_parser` as well.
Whether a response is JSON or SSE is the server's choice, made for each response, and this SDK's own server picks SSE by default,
so a client written for arbitrary servers needs both gems:

```ruby
gem "faraday", ">= 2.0"
gem "event_stream_parser", ">= 1.0"
```

The [Transports](/client/transports/#http-transport-layer) page describes the one setup where `faraday` alone is enough.
