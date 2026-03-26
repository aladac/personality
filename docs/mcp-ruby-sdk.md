---
source: https://github.com/modelcontextprotocol/ruby-sdk
fetched: 2026-03-26
gem: mcp (0.9.1)
---

# MCP Ruby SDK

The official Ruby SDK for Model Context Protocol servers and clients.

## Building an MCP Server

The `MCP::Server` class handles JSON-RPC requests and responses implementing the MCP specification.

### Key Features

- JSON-RPC 2.0 message handling
- Protocol initialization and capability negotiation
- Tool registration and invocation
- Prompt registration and execution
- Resource registration and retrieval
- Stdio & Streamable HTTP transports
- Notifications for list changes (tools, prompts, resources)

### Supported Methods

- `initialize` - Protocol init, returns server capabilities
- `ping` - Health check
- `tools/list` - Lists registered tools and schemas
- `tools/call` - Invokes a tool with arguments
- `prompts/list` - Lists registered prompts
- `prompts/get` - Retrieves a prompt by name
- `resources/list` - Lists registered resources
- `resources/read` - Retrieves a resource by URI
- `resources/templates/list` - Lists resource templates

## Defining Tools

Three ways to define tools:

### 1. Class definition

```ruby
class MyTool < MCP::Tool
  tool_name "my_tool"
  description "Does something"
  input_schema(
    properties: {
      message: { type: "string" },
    },
    required: ["message"]
  )

  def self.call(message:, server_context:)
    MCP::Tool::Response.new([{ type: "text", text: "OK" }])
  end
end
```

### 2. Tool.define

```ruby
tool = MCP::Tool.define(
  name: "my_tool",
  description: "Does something",
) do |args, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: "OK" }])
end
```

### 3. Server#define_tool

```ruby
server.define_tool(
  name: "my_tool",
  description: "Does something",
  input_schema: {
    type: "object",
    properties: { msg: { type: "string" } },
    required: ["msg"]
  }
) do |msg:, server_context:|
  MCP::Tool::Response.new([{ type: "text", text: msg }])
end
```

**Important:** When using `define_tool`, arguments are passed as **keyword args** (splatted from the arguments hash). The `server_context:` keyword is always passed.

### Tool Names

Tool names only allow: `A-Z`, `a-z`, `0-9`, `_`, `-`, `.`

**No `/` allowed.** Use dots for namespacing: `memory.store`, `index.search`.

### Tool Responses

Tools must return `MCP::Tool::Response`:

```ruby
MCP::Tool::Response.new([{ type: "text", text: "result" }])
MCP::Tool::Response.new([{ type: "text", text: "error" }], error: true)
```

## Resources

Register resources with the server:

```ruby
resource = MCP::Resource.new(
  uri: "memory://subjects",
  name: "memory-subjects",
  description: "All subjects",
  mime_type: "application/json",
)

server = MCP::Server.new(name: "my_server", resources: [resource])
# or: server.resources = [resource]
```

Handle reads:

```ruby
server.resources_read_handler do |params|
  [{
    uri: params[:uri],
    mimeType: "application/json",
    text: JSON.generate({ data: "value" })
  }]
end
```

## Server Handle API

Two methods for processing requests:

```ruby
# Hash in, Hash out (symbol keys)
response = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
# => { jsonrpc: "2.0", id: 1, result: { tools: [...] } }

# JSON string in, JSON string out
response = server.handle_json('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
# => '{"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}'
```

**Must call `initialize` before other methods** — the server requires protocol handshake first.

## Stdio Transport

```ruby
server = MCP::Server.new(name: "my_server", version: "1.0")
# ... define tools, resources ...

transport = MCP::Transports::StdioTransport.new(server)
transport.open  # Blocks, reads stdin, writes stdout
```

The transport class is at `MCP::Server::Transports::StdioTransport` (require `mcp/transports/stdio`).

## Client (for connecting to MCP servers)

```ruby
stdio_transport = MCP::Client::Stdio.new(
  command: "bundle",
  args: ["exec", "ruby", "path/to/server.rb"],
  env: { "API_KEY" => "secret" },
  read_timeout: 30
)
client = MCP::Client.new(transport: stdio_transport)

tools = client.tools
response = client.call_tool(tool: tools.first, arguments: { message: "Hello" })
stdio_transport.close
```

## Notifications

```ruby
server.notify_tools_list_changed
server.notify_resources_list_changed
server.notify_log_message(data: { message: "Hello" }, level: "info")
server.notify_progress(progress_token: "token", progress: 50, total: 100)
```

## Configuration

```ruby
# Set server context (passed to tool blocks)
server.server_context = { user_id: 123 }

# Protocol version
server.configuration.protocol_version  # "2024-11-05"
```
