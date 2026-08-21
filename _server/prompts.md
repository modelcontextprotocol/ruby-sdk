---
layout: default
title: Prompts
nav_order: 5
---

# Prompts

MCP spec includes [Prompts](https://modelcontextprotocol.io/specification/latest/server/prompts), which enable servers to define reusable prompt templates and workflows that clients can easily surface to users and LLMs.

## Defining Prompts

The `MCP::Prompt` class provides three ways to create prompts.

### 1. As a class definition with metadata

Subclass `MCP::Prompt` and declare the metadata with class-level helpers; `template` builds the result:

```ruby
class MyPrompt < MCP::Prompt
  prompt_name "my_prompt"  # Optional - defaults to underscored class name
  title "My Prompt"
  description "This prompt performs specific functionality..."
  arguments [
    MCP::Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ]
  meta({ version: "1.0", category: "example" })

  class << self
    def template(args, server_context:)
      MCP::Prompt::Result.new(
        description: "Response description",
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new("User message")
          ),
          MCP::Prompt::Message.new(
            role: "assistant",
            content: MCP::Content::Text.new(args["message"])
          )
        ]
      )
    end
  end
end

prompt = MyPrompt
```

### 2. Using the `MCP::Prompt.define` method

`MCP::Prompt.define` builds a prompt from keyword arguments, with the block as its template:

```ruby
prompt = MCP::Prompt.define(
  name: "my_prompt",
  title: "My Prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    MCP::Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ],
  meta: { version: "1.0", category: "example" }
) do |args, server_context:|
  MCP::Prompt::Result.new(
    description: "Response description",
    messages: [
      MCP::Prompt::Message.new(
        role: "user",
        content: MCP::Content::Text.new("User message")
      ),
      MCP::Prompt::Message.new(
        role: "assistant",
        content: MCP::Content::Text.new(args["message"])
      )
    ]
  )
end
```

### 3. Using the `MCP::Server#define_prompt` method

`MCP::Server#define_prompt` registers the prompt directly on a server instance:

```ruby
server = MCP::Server.new
server.define_prompt(
  name: "my_prompt",
  description: "This prompt performs specific functionality...",
  arguments: [
    Prompt::Argument.new(
      name: "message",
      title: "Message Title",
      description: "Input message",
      required: true
    )
  ],
  meta: { version: "1.0", category: "example" }
) do |args, server_context:|
  Prompt::Result.new(
    description: "Response description",
    messages: [
      Prompt::Message.new(
        role: "user",
        content: Content::Text.new("User message")
      ),
      Prompt::Message.new(
        role: "assistant",
        content: Content::Text.new(args["message"])
      )
    ]
  )
end
```

The [`server_context`](/server/server-context/) parameter is the `server_context` passed into the server and can be used to pass per request information,
e.g. around authentication state or user preferences.

## Key Components

- `MCP::Prompt::Argument` - Defines input parameters for the prompt template with name, title, description, and required flag
- `MCP::Prompt::Message` - Represents a message in the conversation with a role and content
- `MCP::Prompt::Result` - The output of a prompt template containing description and messages
- `MCP::Content::Text` - Text content for messages

## Registering Prompts

Register prompts with the MCP server:

```ruby
server = MCP::Server.new(
  name: "my_server",
  prompts: [MyPrompt],
  server_context: { user_id: current_user.id },
)
```

The server will handle prompt listing and execution through the MCP protocol methods:

- `prompts/list` - Lists all registered prompts and their schemas
- `prompts/get` - Retrieves and executes a specific prompt with arguments

## Prompts with Image and Embedded Resource Content

Prompt messages are not limited to text. The same `MCP::Content` types used in [tool responses](/server/tools/) can be used as message content,
letting a prompt template include images or inline resource contents. Unlike tool responses, the content object is passed directly rather than as a hash;
`MCP::Prompt::Message` serializes it when the prompt result is returned:

```ruby
class CodeReviewPrompt < MCP::Prompt
  prompt_name "code_review"
  description "Review a source file with an accompanying diagram"
  arguments [
    MCP::Prompt::Argument.new(name: "file_uri", description: "URI of the file to review", required: true),
  ]

  class << self
    def template(args, server_context:)
      MCP::Prompt::Result.new(
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::EmbeddedResource.new(
              MCP::Resource::TextContents.new(
                uri: args["file_uri"],
                mime_type: "text/x-ruby",
                text: read_source(args["file_uri"]),
              ),
            ),
          ),
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Image.new(architecture_diagram_base64, "image/png"),
          ),
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new("Please review the code above, using the diagram for context."),
          ),
        ],
      )
    end
  end
end
```
