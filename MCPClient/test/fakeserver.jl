# A fake MCP server built on HTTP.serve!, so the whole suite runs offline.
#
# It is deliberately literal about the protocol: it checks the headers the client
# is supposed to send and records every message it receives, so the tests can
# assert on what went over the wire rather than only on what came back.

using HTTP, JSON, Sockets

mutable struct FakeServer
    server::Any
    url::String
    received::Vector{Any}          # every decoded JSON-RPC message, in order
    headers::Vector{Any}           # the headers that accompanied each message
    methods::Vector{String}        # HTTP methods seen, so DELETE is observable
    session::String
    lock::ReentrantLock
end

port_of(server) = HTTP.port(server)

"""
    fake_server(dispatch; session="sess-1") -> FakeServer

`dispatch(fs, msg, req) -> HTTP.Response` decides how one JSON-RPC message is
answered. Returning `nothing` means "202 Accepted with no body", the correct
answer to a notification.
"""
function fake_server(dispatch; session::AbstractString="sess-1")
    fs = FakeServer(nothing, "", Any[], Any[], String[], String(session), ReentrantLock())
    handler = function (req::HTTP.Request)
        @lock fs.lock push!(fs.methods, req.method)
        if req.method == "DELETE"
            return HTTP.Response(200, "")
        end
        body = String(req.body)
        msg = isempty(body) ? nothing : JSON.parse(body)
        @lock fs.lock begin
            push!(fs.received, msg)
            push!(fs.headers, req.headers)
        end
        response = dispatch(fs, msg, req)
        return response === nothing ? HTTP.Response(202, "") : response
    end
    server = HTTP.serve!(handler, "127.0.0.1", 0; listenany=true)
    fs.server = server
    fs.url = "http://127.0.0.1:$(port_of(server))/mcp"
    return fs
end

Base.close(fs::FakeServer) = close(fs.server)

"Every decoded message the server received, in order, objects only."
received_messages(fs::FakeServer) =
    @lock fs.lock Any[m for m in fs.received if m isa AbstractDict]

received_methods(fs::FakeServer) =
    @lock fs.lock String[m["method"] for m in fs.received if m isa AbstractDict && haskey(m, "method")]

header_for(fs::FakeServer, index::Int, name::AbstractString) =
    @lock fs.lock HTTP.header(fs.headers[index], name, "")

json_response(payload) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(payload))

"""
    sse_response(messages...; session=nothing)

Frame each message as one SSE event, the way a streamable-HTTP server does when
it wants to interleave notifications with the response.
"""
function sse_response(messages...; session=nothing)
    io = IOBuffer()
    # A comment line is a keep-alive; the client must not treat it as an event.
    print(io, ": keep-alive\n\n")
    for (i, m) in enumerate(messages)
        print(io, "event: message\n")
        print(io, "id: ", i, "\n")
        print(io, "data: ", JSON.json(m), "\n\n")
    end
    headers = ["Content-Type" => "text/event-stream"]
    session === nothing || push!(headers, "Mcp-Session-Id" => session)
    return HTTP.Response(200, headers, String(take!(io)))
end

result_for(msg, result) =
    Dict("jsonrpc" => "2.0", "id" => msg["id"], "result" => result)

error_for(msg, code, message; data=nothing) = Dict(
    "jsonrpc" => "2.0", "id" => msg["id"],
    "error" => data === nothing ? Dict("code" => code, "message" => message) :
               Dict("code" => code, "message" => message, "data" => data))

initialize_result(; version="2025-06-18", capabilities=Dict("tools" => Dict("listChanged" => true)),
                  instructions=nothing) = begin
    r = Dict{String,Any}("protocolVersion" => version, "capabilities" => capabilities,
                         "serverInfo" => Dict("name" => "fake-mcp", "version" => "9.9.9"))
    instructions === nothing || (r["instructions"] = instructions)
    r
end

text_tool_result(text; is_error=false) =
    Dict("content" => [Dict("type" => "text", "text" => text)], "isError" => is_error)

# Poll instead of sleeping a fixed amount: everything here crosses a process
# boundary, so the only safe wait is one that ends when the condition holds.
function wait_until(predicate; seconds::Real=10.0)
    deadline = time() + seconds
    while time() < deadline
        predicate() && return true
        sleep(0.02)
    end
    return predicate()
end
