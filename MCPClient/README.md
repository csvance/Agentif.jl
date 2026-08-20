# MCPClient

A Julia client for the [Model Context Protocol](https://modelcontextprotocol.io),
the JSON-RPC 2.0 protocol that language-model applications use to discover and
call tools hosted by a separate server.

Both standard transports are implemented:

- `StreamableHTTPTransport` for a server reached over HTTP, including the SSE
  response stream and `Mcp-Session-Id` session handling
- `StdioTransport` for a server run as a child process, with newline-delimited
  JSON framing over its stdin/stdout (see [`STDIO.md`](STDIO.md) for the design)

The protocol layer above them is shared, so nothing in `Client` is transport
specific. The package depends only on `HTTP`, `JSON` and `Base64`, which keeps it
usable outside the `Agentif` stack.

## Usage

```julia
using MCPClient

client = Client("http://127.0.0.1:8931/mcp")
for tool in list_tools(client)
    println(tool.name, ": ", tool.description)
end
result = call_tool(client, "get_weather", Dict{String, Any}("city" => "Houston"))
result.is_error || println(content_text(result))
close(client)
```

A server that runs locally is reached the same way, with a command instead of a
URL:

```julia
client = Client(`npx -y @modelcontextprotocol/server-everything`)
```

The two-argument form closes the client for you, even if the body throws:

```julia
tools = Client(`npx -y @modelcontextprotocol/server-everything`) do client
    list_tools(client)
end
```

## Protocol surface

`Client` performs the `initialize` handshake on construction and sends the
`notifications/initialized` acknowledgement, then exposes what the server
reported through `server_info`, `server_capabilities`, `server_instructions`,
`protocol_version`, `session_id` and `has_capability`.

Tool discovery is `list_tools`, which follows `nextCursor` to the end of the
listing and refuses to loop on a server that repeats a cursor or never
terminates; `list_tools_page` is there when you want to page manually. Tool
invocation is `call_tool`, which returns a `ToolResult`.

Methods this package does not wrap are still reachable through `request` and
`notify_server`, which take a raw method name and params.

Requested protocol revision is `2025-06-18`; `2025-03-26` and `2024-11-05` are
also accepted during negotiation.

## Results and content

A tool result is a list of typed content blocks, not a string. `content_text`
gives you the text to hand back to a model; the blocks themselves stay available
as `TextContent`, `ImageContent`, `AudioContent`, `EmbeddedResource`,
`ResourceLink` or `UnknownContent`, and every block keeps the `raw` dictionary it
was parsed from so annotations and vendor extensions remain reachable. A block
type from a newer spec revision becomes `UnknownContent` rather than an error.

`MCPTool` exposes `name`, `description`, `input_schema` and `output_schema` as
plain Julia values, so a wrapper can map them onto an agent framework's tool type
without unwrapping anything.

## Errors

A tool that *reports* failure is data, not an exception: the result comes back
with `is_error` set, because that text is normally fed to the model so it can try
something else. Exceptions are reserved for the call not happening:

- `JSONRPCError`: the server rejected the request (unknown tool, bad arguments)
- `MCPTimeoutError`: no reply within the deadline
- `MCPTransportError`: the message could not be exchanged at all
- `MCPProtocolError`: the peer answered, but not with valid MCP

All four are subtypes of `MCPException`.

## Server-initiated traffic

Pass `on_notification = f(message)` to observe notifications such as
`notifications/tools/list_changed` or the `notifications/progress` stream a call
emits when given a `progress_token`. Pass `on_request = f(method, params)` to
answer server-initiated requests; without one, everything except `ping` is
answered "method not found". `ping` is always answered, since a client that
ignores it looks dead.

## Testing

```bash
julia --project=. MCPClient/test/runtests.jl
```

The suite needs no network access and no MCP server on the host: the HTTP tests
run against an in-process fake server, and the stdio tests spawn a Julia child
process that speaks the protocol.
