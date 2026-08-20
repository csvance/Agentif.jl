"""
    MCPClient

A client for the Model Context Protocol, the JSON-RPC 2.0 protocol that language
model applications use to discover and call tools hosted by a separate server.

Both standard transports are implemented: [`StreamableHTTPTransport`](@ref) for a
server reached over HTTP, and [`StdioTransport`](@ref) for one run as a child
process. Each is an [`AbstractTransport`](@ref); the protocol layer above them is
shared. See `STDIO.md` for the stdio design.

Typical use:

```julia
using MCPClient

client = Client("http://127.0.0.1:8931/mcp")
for tool in list_tools(client)
    println(tool.name, ": ", tool.description)
end
result = call_tool(client, "get_weather", Dict{String,Any}("city" => "Houston"))
result.is_error || println(content_text(result))
close(client)
```

A server that runs locally is reached the same way, with a command instead of a
URL:

```julia
client = Client(`npx -y @modelcontextprotocol/server-everything`)
```

This package depends only on HTTP, JSON and Base64, so it can be wrapped for any
agent framework without dragging one in.
"""
module MCPClient

using Base64: base64decode
using HTTP
using JSON

export Client,
    MCPTool,
    ToolResult,
    ContentBlock,
    TextContent,
    ImageContent,
    AudioContent,
    EmbeddedResource,
    ResourceLink,
    UnknownContent,
    StreamableHTTPTransport,
    StdioTransport,
    AbstractTransport,
    MCPException,
    JSONRPCError,
    MCPTimeoutError,
    MCPTransportError,
    MCPProtocolError,
    initialize!,
    list_tools,
    list_tools_page,
    call_tool,
    ping,
    notify_server,
    content_text,
    server_info,
    server_capabilities,
    server_instructions,
    protocol_version,
    session_id,
    has_capability

include("errors.jl")
include("jsonrpc.jl")
include("sse.jl")
include("transport.jl")
include("http_transport.jl")
include("stdio_transport.jl")
include("content.jl")
include("client.jl")

end # module
