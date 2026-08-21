# MCPClient

A Julia client for the [Model Context Protocol](https://modelcontextprotocol.io),
the JSON-RPC 2.0 protocol that language-model applications use to discover and
call tools hosted by a separate server.

Both standard transports are implemented:

- `StreamableHTTPTransport` for a server reached over HTTP, including the SSE
  response stream and `Mcp-Session-Id` session handling
- `StdioTransport` for a server run as a child process, with newline-delimited
  JSON framing over its stdin/stdout

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

Giving up on a deadline also tells the server so, with the specification's
`notifications/cancelled` for that request id, because the server is still
working on it: without that, an abandoned tool runs to completion and writes its
result to nobody. `initialize` is the exception, which the specification says must
not be cancelled.

A transport can also be finished off from the far side, and `is_open` says so
rather than leaving you to find out one failed call at a time: a stdio child that
exits, or an HTTP server that declares its session gone with a 404.

All four are subtypes of `MCPException`, and that is exhaustive: every field this
package narrows to a `String` or a `Dict` is type-checked at the wire boundary, so
a server that puts a number where the spec says string produces an
`MCPProtocolError` rather than a `MethodError` escaping past a
`catch e isa MCPException`.

## Server-initiated traffic

Pass `on_notification = f(message)` to observe notifications such as
`notifications/tools/list_changed` or the `notifications/progress` stream a call
emits when given a `progress_token`. Handlers run in order on one dedicated task,
so a handler may call back into the client, and a slow or throwing one delays or
skips later notifications without ever stalling the transport.

Pass `on_request = f(method, params)` to answer server-initiated requests;
without one, everything except `ping` is answered "method not found". `ping` is
always answered, since a client that ignores it looks dead.

Both transports deliver the server's own traffic whether or not a request of
yours is outstanding, but they get there differently. Stdio has one stream and
always did. Streamable HTTP has no reply for a between-requests notification to
travel with, so the client opens the specification's standalone `GET` stream once
the handshake completes, reconnecting and resuming with `Last-Event-ID` if it
drops. That stream is only opened when you passed a handler, since holding a
connection open to dispatch into nothing is pure cost, and a server may decline
it with HTTP 405, in which case only notifications interleaved into a reply are
seen and the client stops asking.

## Closing

`close` releases the transport and is safe to call more than once. A request
still in flight fails with `MCPTransportError` rather than waiting out its
deadline, on both transports, which matters most when that deadline is "never"
(`timeout <= 0`). A handshake that fails closes the transport it was given, so a
failed `Client(...)` never leaves a socket, a server-side session or a child
process behind.

## Testing

```bash
julia --project=. MCPClient/test/runtests.jl
```

The suite needs no network access and no MCP server on the host: the HTTP tests
run against an in-process fake server, and the stdio tests spawn a Julia child
process that speaks the protocol.

There is a second suite that runs the reference server,
`@modelcontextprotocol/server-everything`, over both transports, so the same
assertions cover a real child process and a real HTTP endpoint. It needs `npx`,
and network access the first time, so it is opt-in:

```bash
MCPCLIENT_INTEGRATION=1 julia --project=. MCPClient/test/runtests.jl
```

The server version is pinned; `MCPCLIENT_EVERYTHING` overrides it.
