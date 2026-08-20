using Test
using MCPClient
using MCPClient: SSEParser, feed_line!, parse_sse, parse_payload, ids_equal, plain,
                 unwrap_result, parse_content, request, StreamableHTTPTransport,
                 LATEST_PROTOCOL_VERSION
using HTTP, JSON, Base64

include("fakeserver.jl")

# A default dispatcher covering the happy path, so each test only overrides what
# it cares about.
function default_dispatch(fs, msg, req)
    msg === nothing && return nothing
    method = get(msg, "method", "")
    if method == "initialize"
        return HTTP.Response(200,
            ["Content-Type" => "application/json", "Mcp-Session-Id" => fs.session],
            JSON.json(result_for(msg, initialize_result(instructions = "be brief"))))
    elseif method == "ping"
        return json_response(result_for(msg, Dict()))
    elseif method == "tools/list"
        return json_response(result_for(msg, Dict("tools" => [Dict(
            "name" => "echo", "description" => "Echo text back",
            "inputSchema" => Dict("type" => "object",
                                  "properties" => Dict("text" => Dict("type" => "string")),
                                  "required" => ["text"]))])))
    elseif method == "tools/call"
        args = get(msg["params"], "arguments", Dict())
        return json_response(result_for(msg, text_tool_result(get(args, "text", ""))))
    elseif startswith(method, "notifications/")
        return nothing
    end
    return json_response(error_for(msg, -32601, "no such method: $method"))
end

with_server(f, dispatch=default_dispatch; kwargs...) = begin
    fs = fake_server(dispatch; kwargs...)
    try
        f(fs)
    finally
        close(fs)
    end
end

@testset "MCPClient" begin

@testset "SSE framing" begin
    events = parse_sse(": comment\n\nevent: message\ndata: {\"a\":1}\n\n")
    @test length(events) == 1
    @test events[1].event == "message"
    @test events[1].data == "{\"a\":1}"

    # Multi-line data is joined with newlines, matching EventSource.
    events = parse_sse("data: one\ndata: two\n\n")
    @test events[1].data == "one\ntwo"

    # CRLF terminators and a missing trailing blank line are both tolerated.
    events = parse_sse("id: 7\r\ndata: x\r\n\r\ndata: y\n")
    @test length(events) == 2
    @test events[1].id == "7"
    @test events[2].data == "y"

    # An event with no data is bookkeeping, not a message.
    @test isempty(parse_sse("id: 3\n\n"))

    # Only one leading space is stripped from a value.
    @test parse_sse("data:  padded\n\n")[1].data == " padded"

    p = SSEParser()
    @test feed_line!(p, "data: partial") === nothing
    @test feed_line!(p, "").data == "partial"
end

@testset "JSON-RPC layer" begin
    @test parse_payload("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}") isa Vector{Dict{String,Any}}
    @test length(parse_payload("[{\"id\":1},{\"id\":2}]")) == 2
    @test_throws MCPProtocolError parse_payload("not json")
    @test_throws MCPProtocolError parse_payload("\"a string\"")

    # Ids survive a JSON round trip that changes their type.
    @test ids_equal(1, 1)
    @test ids_equal(1, 1.0)
    @test ids_equal("abc", "abc")
    @test !ids_equal(1, 2)
    @test !ids_equal(nothing, nothing)

    # Parsed JSON becomes plain Julia containers, not JSON.Object.
    p = plain(JSON.parse("{\"a\":{\"b\":[1,{\"c\":2}]}}"))
    @test p isa Dict{String,Any}
    @test p["a"]["b"][2] isa Dict{String,Any}

    err = try
        unwrap_result(Dict{String,Any}("id" => 1, "error" =>
            Dict("code" => -32602, "message" => "bad params", "data" => Dict("field" => "x"))), "tools/call")
        nothing
    catch e
        e
    end
    @test err isa JSONRPCError
    @test err.code == -32602
    @test err.message == "bad params"
    @test err.data["field"] == "x"
    @test err.method == "tools/call"
    @test occursin("bad params", sprint(showerror, err))

    @test_throws MCPProtocolError unwrap_result(Dict{String,Any}("id" => 1), "ping")
    @test unwrap_result(Dict{String,Any}("id" => 1, "result" => Dict("k" => 1)), "ping")["k"] == 1
end

@testset "content blocks" begin
    result = ToolResult(Dict{String,Any}(
        "content" => [
            Dict("type" => "text", "text" => "hello"),
            Dict("type" => "image", "data" => base64encode("PNGDATA"), "mimeType" => "image/png"),
            Dict("type" => "audio", "data" => base64encode("WAV"), "mimeType" => "audio/wav"),
            Dict("type" => "resource", "resource" => Dict("uri" => "file:///a.txt",
                                                         "mimeType" => "text/plain",
                                                         "text" => "world")),
            Dict("type" => "resource_link", "uri" => "file:///b.txt", "name" => "b"),
            Dict("type" => "something_new", "payload" => 1),
        ],
        "structuredContent" => Dict("ok" => true)))

    @test length(result.content) == 6
    @test result.content[1] isa TextContent
    @test result.content[2] isa ImageContent
    @test String(result.content[2].data) == "PNGDATA"
    @test result.content[2].mime_type == "image/png"
    @test result.content[3] isa AudioContent
    @test result.content[4] isa EmbeddedResource
    @test result.content[4].uri == "file:///a.txt"
    @test result.content[5] isa ResourceLink
    @test result.content[5].name == "b"
    # Unknown block types are kept rather than rejected, so a newer server does
    # not break an older client.
    @test result.content[6] isa UnknownContent
    @test result.content[6].raw["payload"] == 1
    @test result.structured_content["ok"] == true
    @test !result.is_error

    # Text from the blocks that have any, joined; nothing else is invented.
    @test content_text(result) == "hello\nworld"

    blob = ToolResult(Dict{String,Any}("content" => [Dict("type" => "resource",
        "resource" => Dict("uri" => "file:///c.bin", "blob" => base64encode("BYTES")))]))
    @test String(blob.content[1].blob) == "BYTES"

    @test_throws MCPProtocolError parse_content(Dict{String,Any}("text" => "no type"))
    @test_throws MCPProtocolError parse_content(Dict{String,Any}("type" => "image", "data" => "!!!not base64!!!"))
    @test_throws MCPProtocolError ToolResult(Dict{String,Any}("content" => "not an array"))

    tool = MCPTool(Dict{String,Any}("name" => "search", "description" => "find things",
                                    "inputSchema" => Dict("type" => "object"),
                                    "outputSchema" => Dict("type" => "object"),
                                    "title" => "Search"))
    @test tool.name == "search"
    @test tool.input_schema isa Dict{String,Any}
    @test tool.output_schema !== nothing
    @test tool.title == "Search"
    @test_throws MCPProtocolError MCPTool(Dict{String,Any}("description" => "nameless"))
end

@testset "initialize handshake and session id" begin
    with_server() do fs
        client = Client(fs.url)
        try
            @test server_info(client)["name"] == "fake-mcp"
            @test protocol_version(client) == LATEST_PROTOCOL_VERSION
            @test server_capabilities(client)["tools"]["listChanged"] == true
            @test server_instructions(client) == "be brief"
            @test has_capability(client, "tools")
            @test !has_capability(client, "prompts")
            @test session_id(client) == fs.session

            # The handshake is initialize followed by the initialized notification.
            @test received_methods(fs)[1:2] == ["initialize", "notifications/initialized"]

            init = fs.received[1]
            @test init["params"]["protocolVersion"] == LATEST_PROTOCOL_VERSION
            @test init["params"]["clientInfo"]["name"] == "MCPClient.jl"
            @test haskey(init["params"], "capabilities")
            @test init["id"] == 1

            # The session id only exists after initialize, so it is absent on that
            # first request and present on every later one.
            @test header_for(fs, 1, "Mcp-Session-Id") == ""
            @test header_for(fs, 2, "Mcp-Session-Id") == fs.session
            @test header_for(fs, 2, "MCP-Protocol-Version") == LATEST_PROTOCOL_VERSION
            @test occursin("application/json", header_for(fs, 1, "Accept"))
            @test occursin("text/event-stream", header_for(fs, 1, "Accept"))

            ping(client)
            @test header_for(fs, 3, "Mcp-Session-Id") == fs.session
            # Request ids are unique and monotonic.
            @test fs.received[3]["id"] == 2
        finally
            close(client)
        end
        @test "DELETE" in fs.methods
    end
end

@testset "custom headers and client identity" begin
    with_server() do fs
        client = Client(fs.url; headers = ["Authorization" => "Bearer secret"],
                        name = "AgentRevise", version = "1.2.3")
        try
            @test header_for(fs, 1, "Authorization") == "Bearer secret"
            @test fs.received[1]["params"]["clientInfo"]["name"] == "AgentRevise"
            @test fs.received[1]["params"]["clientInfo"]["version"] == "1.2.3"
        finally
            close(client)
        end
    end
end

@testset "protocol version negotiation" begin
    # An older revision the client knows is accepted.
    with_server() do fs
        dispatch = (fs, msg, req) -> get(msg, "method", "") == "initialize" ?
            json_response(result_for(msg, initialize_result(version = "2024-11-05"))) :
            default_dispatch(fs, msg, req)
        fs2 = fake_server(dispatch)
        try
            client = Client(fs2.url)
            @test protocol_version(client) == "2024-11-05"
            close(client)
        finally
            close(fs2)
        end
    end

    # One the client does not know is refused by default.
    dispatch = (fs, msg, req) -> get(msg, "method", "") == "initialize" ?
        json_response(result_for(msg, initialize_result(version = "1999-01-01"))) :
        default_dispatch(fs, msg, req)
    fs = fake_server(dispatch)
    try
        @test_throws MCPProtocolError Client(fs.url)
        client = (@test_logs (:warn,) match_mode = :any Client(fs.url; strict_version = false))
        @test protocol_version(client) == "1999-01-01"
        close(client)
    finally
        close(fs)
    end
end

@testset "tools/list pagination" begin
    pages = Dict(
        "" => Dict("tools" => [Dict("name" => "a", "inputSchema" => Dict("type" => "object"))],
                   "nextCursor" => "page2"),
        "page2" => Dict("tools" => [Dict("name" => "b", "description" => "second",
                                         "inputSchema" => Dict("type" => "object"))],
                        "nextCursor" => "page3"),
        "page3" => Dict("tools" => [Dict("name" => "c", "inputSchema" => Dict("type" => "object"))]),
    )
    dispatch = function (fs, msg, req)
        get(msg, "method", "") == "tools/list" || return default_dispatch(fs, msg, req)
        cursor = get(get(msg, "params", Dict()), "cursor", "")
        return json_response(result_for(msg, pages[cursor]))
    end
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            tools = list_tools(client)
            @test [t.name for t in tools] == ["a", "b", "c"]
            @test tools[2].description == "second"
            @test tools[1].description == ""

            # The cursor from one page is what the next request carries.
            calls = [m for m in fs.received if get(m, "method", "") == "tools/list"]
            @test length(calls) == 3
            @test !haskey(calls[1]["params"], "cursor")
            @test calls[2]["params"]["cursor"] == "page2"
            @test calls[3]["params"]["cursor"] == "page3"

            # Manual paging exposes the same cursors.
            page, cursor = list_tools_page(client)
            @test cursor == "page2"
            @test length(page) == 1
        finally
            close(client)
        end
    end

    # A server that never stops paginating must not hang the caller.
    stuck = (fs, msg, req) -> get(msg, "method", "") == "tools/list" ?
        json_response(result_for(msg, Dict("tools" => [], "nextCursor" => "same"))) :
        default_dispatch(fs, msg, req)
    with_server(stuck) do fs
        client = Client(fs.url)
        try
            @test_throws MCPProtocolError list_tools(client)
        finally
            close(client)
        end
    end
end

@testset "tools/call" begin
    with_server() do fs
        client = Client(fs.url)
        try
            result = call_tool(client, "echo", Dict{String,Any}("text" => "hi there"))
            @test result isa ToolResult
            @test !result.is_error
            @test content_text(result) == "hi there"

            call = fs.received[end]
            @test call["params"]["name"] == "echo"
            @test call["params"]["arguments"]["text"] == "hi there"

            # A NamedTuple is accepted as a convenience.
            @test content_text(call_tool(client, "echo", (text = "tuple",))) == "tuple"
            # Arguments are always sent, even when empty.
            call_tool(client, "echo")
            @test fs.received[end]["params"]["arguments"] == Dict()
            @test_throws ArgumentError call_tool(client, "echo", "not a dict")
        finally
            close(client)
        end
    end
end

@testset "tool failure is data, not an exception" begin
    dispatch = (fs, msg, req) -> get(msg, "method", "") == "tools/call" ?
        json_response(result_for(msg, text_tool_result("the API key is invalid"; is_error = true))) :
        default_dispatch(fs, msg, req)
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            result = call_tool(client, "broken")
            @test result.is_error
            @test content_text(result) == "the API key is invalid"
            @test occursin("isError", sprint(show, result))
        finally
            close(client)
        end
    end
end

@testset "JSON-RPC error becomes a typed exception" begin
    dispatch = function (fs, msg, req)
        if get(msg, "method", "") == "tools/call" && msg["params"]["name"] == "nope"
            return json_response(error_for(msg, -32602, "Unknown tool: nope"; data = Dict("tool" => "nope")))
        end
        return default_dispatch(fs, msg, req)
    end
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            err = try
                call_tool(client, "nope")
                nothing
            catch e
                e
            end
            @test err isa JSONRPCError
            @test err isa MCPException
            @test err.code == -32602
            @test err.data["tool"] == "nope"
            @test err.method == "tools/call"
            # The session survives a rejected request.
            @test content_text(call_tool(client, "echo")) == ""
        finally
            close(client)
        end
    end
end

@testset "SSE-framed responses" begin
    notes = Any[]
    dispatch = function (fs, msg, req)
        method = get(msg, "method", "")
        if method == "initialize"
            # Even the handshake may come back as an event stream.
            return sse_response(result_for(msg, initialize_result()); session = fs.session)
        elseif method == "tools/call"
            # A progress notification ahead of the response is the whole point of
            # answering with a stream.
            return sse_response(
                Dict("jsonrpc" => "2.0", "method" => "notifications/progress",
                     "params" => Dict("progress" => 1, "total" => 2)),
                result_for(msg, text_tool_result("streamed")))
        end
        return default_dispatch(fs, msg, req)
    end
    with_server(dispatch) do fs
        client = Client(fs.url; on_notification = m -> push!(notes, m))
        try
            @test session_id(client) == fs.session
            @test content_text(call_tool(client, "echo")) == "streamed"
            @test length(notes) == 1
            @test notes[1]["method"] == "notifications/progress"
            @test notes[1]["params"]["total"] == 2
        finally
            close(client)
        end
    end
end

@testset "server-initiated request over SSE" begin
    dispatch = function (fs, msg, req)
        method = get(msg, "method", "")
        if method == "tools/call"
            return sse_response(Dict("jsonrpc" => "2.0", "id" => "srv-1", "method" => "ping"),
                                result_for(msg, text_tool_result("done")))
        end
        return default_dispatch(fs, msg, req)
    end
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            @test content_text(call_tool(client, "echo")) == "done"
            # The client answers the server's ping on a POST of its own.
            replies = Any[]
            for _ in 1:100
                replies = [m for m in fs.received if m isa AbstractDict && get(m, "id", nothing) == "srv-1"]
                isempty(replies) || break
                sleep(0.02)
            end
            @test length(replies) == 1
            @test replies[1]["result"] == Dict()
        finally
            close(client)
        end
    end

    # Without an on_request handler, anything but ping is refused properly.
    dispatch2 = function (fs, msg, req)
        method = get(msg, "method", "")
        if method == "tools/call"
            return sse_response(Dict("jsonrpc" => "2.0", "id" => "srv-2",
                                     "method" => "sampling/createMessage", "params" => Dict()),
                                result_for(msg, text_tool_result("done")))
        end
        return default_dispatch(fs, msg, req)
    end
    with_server(dispatch2) do fs
        client = Client(fs.url)
        try
            call_tool(client, "echo")
            replies = Any[]
            for _ in 1:100
                replies = [m for m in fs.received if m isa AbstractDict && get(m, "id", nothing) == "srv-2"]
                isempty(replies) || break
                sleep(0.02)
            end
            @test length(replies) == 1
            @test replies[1]["error"]["code"] == -32601
        finally
            close(client)
        end
    end
end

@testset "notifications" begin
    with_server() do fs
        client = Client(fs.url)
        try
            notify_server(client, "notifications/cancelled", Dict("requestId" => 7))
            sent = fs.received[end]
            @test sent["method"] == "notifications/cancelled"
            @test !haskey(sent, "id")
            @test sent["params"]["requestId"] == 7
        finally
            close(client)
        end
    end
end

@testset "a server that never answers times out" begin
    stop = Ref(false)
    dispatch = function (fs, msg, req)
        if get(msg, "method", "") == "tools/call"
            while !stop[]
                sleep(0.05)
            end
        end
        return default_dispatch(fs, msg, req)
    end
    fs = fake_server(dispatch)
    client = Client(fs.url; timeout = 20)
    try
        elapsed = @elapsed err = try
            call_tool(client, "slow"; timeout = 0.5)
            nothing
        catch e
            e
        end
        @test err isa MCPTimeoutError
        @test err.method == "tools/call"
        @test err.timeout == 0.5
        # The deadline is honoured rather than merely eventually noticed.
        @test elapsed < 5
        @test occursin("tools/call", sprint(showerror, err))

        # The client is still usable for a request the server does answer.
        @test ping(client; timeout = 5) === nothing
    finally
        stop[] = true
        close(client)
        close(fs)
    end
end

@testset "connection failures are typed" begin
    # Nothing is listening on this port: the handshake must fail fast and loudly.
    listener = HTTP.serve!(req -> HTTP.Response(200, ""), "127.0.0.1", 0; listenany=true)
    dead_url = "http://127.0.0.1:$(port_of(listener))/mcp"
    close(listener)
    sleep(0.2)
    @test_throws MCPTransportError Client(dead_url; timeout = 5)
end

@testset "HTTP-level failures" begin
    with_server((fs, msg, req) -> HTTP.Response(500, "boom")) do fs
        @test_throws MCPTransportError Client(fs.url)
    end

    # A 404 once a session exists means the server dropped it.
    # The handshake succeeds, then the server forgets the session.
    dispatch = function (fs, msg, req)
        method = get(msg, "method", "")
        (method == "initialize" || startswith(method, "notifications/")) &&
            return default_dispatch(fs, msg, req)
        return HTTP.Response(404, "unknown session")
    end
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            err = try
                ping(client)
                nothing
            catch e
                e
            end
            @test err isa MCPTransportError
            @test occursin("no longer valid", err.message)
        finally
            close(client)
        end
    end

    # A body that is not JSON is a protocol error, not a crash.
    dispatch = (fs, msg, req) -> get(msg, "method", "") == "initialize" ?
        HTTP.Response(200, ["Content-Type" => "application/json"], "<html>nope</html>") :
        default_dispatch(fs, msg, req)
    with_server(dispatch) do fs
        @test_throws MCPProtocolError Client(fs.url)
    end

    # 202 with no body to a request is a server bug, and is reported as one.
    dispatch = (fs, msg, req) -> get(msg, "method", "") == "initialize" ? nothing :
        default_dispatch(fs, msg, req)
    with_server(dispatch) do fs
        @test_throws MCPProtocolError Client(fs.url)
    end
end

@testset "closed client refuses further work" begin
    with_server() do fs
        client = Client(fs.url)
        close(client)
        close(client)  # idempotent
        @test_throws MCPTransportError ping(client)
    end
end

@testset "do-block form closes the client" begin
    with_server() do fs
        result = Client(fs.url) do client
            content_text(call_tool(client, "echo", Dict{String,Any}("text" => "scoped")))
        end
        @test result == "scoped"
        @test "DELETE" in fs.methods

        # It closes on failure too.
        @test_throws ErrorException Client(fs.url) do client
            error("boom")
        end
    end
end

@testset "raw request escape hatch" begin
    dispatch = (fs, msg, req) -> get(msg, "method", "") == "resources/list" ?
        json_response(result_for(msg, Dict("resources" => [Dict("uri" => "file:///x")]))) :
        default_dispatch(fs, msg, req)
    with_server(dispatch) do fs
        client = Client(fs.url)
        try
            result = request(client, "resources/list", Dict{String,Any}())
            @test result["resources"][1]["uri"] == "file:///x"
        finally
            close(client)
        end
    end
end

@testset "transport without a handshake" begin
    with_server() do fs
        transport = StreamableHTTPTransport(fs.url; timeout = 5)
        client = Client(transport; initialize = false)
        try
            @test occursin("not initialized", sprint(show, client))
            initialize!(client)
            @test protocol_version(client) == LATEST_PROTOCOL_VERSION
            # Initializing twice is a no-op rather than a second handshake.
            initialize!(client)
            @test count(==("initialize"), received_methods(fs)) == 1
        finally
            close(client)
        end
    end
end

# --- regressions from code review -----------------------------------------

# Everything below covers a defect found in review: a server that sends the wrong
# type where the spec says string used to raise MethodError, which is not an
# MCPException, so a caller guarding with `catch e isa MCPException` saw an
# escaping crash and read a server's sloppiness as a bug in its own code.
@testset "a wrong-typed field is a protocol error, not a MethodError" begin
    # Each case is (description, the tools/call result the server returns).
    malformed_results = [
        "mimeType of an image" => Dict("content" => [Dict("type" => "image", "data" => "AAAA", "mimeType" => 42)]),
        "mimeType as an object" => Dict("content" => [Dict("type" => "image", "data" => "AAAA", "mimeType" => Dict())]),
        "text of a text block" => Dict("content" => [Dict("type" => "text", "text" => 7)]),
        "resource.uri" => Dict("content" => [Dict("type" => "resource", "resource" => Dict("uri" => 1, "text" => "x"))]),
        "resource.text" => Dict("content" => [Dict("type" => "resource", "resource" => Dict("uri" => "u", "text" => 2))]),
        "resource_link.uri" => Dict("content" => [Dict("type" => "resource_link", "uri" => 3, "name" => "n")]),
        "resource_link.name" => Dict("content" => [Dict("type" => "resource_link", "uri" => "u", "name" => 4)]),
        "structuredContent as an array" => Dict("content" => [], "structuredContent" => [1, 2]),
        "both text and blob on a resource" =>
            Dict("content" => [Dict("type" => "resource", "resource" => Dict("uri" => "u", "text" => "t", "blob" => "AAAA"))]),
    ]
    for (label, result) in malformed_results
        @testset "$label" begin
            with_server((fs, msg, req) -> begin
                msg === nothing && return nothing
                get(msg, "method", "") == "tools/call" ?
                    json_response(result_for(msg, result)) : default_dispatch(fs, msg, req)
            end) do fs
                Client(fs.url; timeout = 5) do client
                    err = try
                        call_tool(client, "echo", Dict{String,Any}())
                        nothing
                    catch e
                        e
                    end
                    @test err isa MCPException
                    @test err isa MCPProtocolError
                end
            end
        end
    end
end

@testset "a malformed tools/list entry is a protocol error" begin
    for entries in ([("not an object")], [Dict("name" => "ok", "description" => 5)],
                    [Dict("name" => "ok", "inputSchema" => [1])],
                    [Dict("name" => "ok", "title" => 9)])
        with_server((fs, msg, req) -> begin
            msg === nothing && return nothing
            get(msg, "method", "") == "tools/list" ?
                json_response(result_for(msg, Dict("tools" => entries))) : default_dispatch(fs, msg, req)
        end) do fs
            Client(fs.url; timeout = 5) do client
                err = try
                    list_tools(client)
                    nothing
                catch e
                    e
                end
                @test err isa MCPProtocolError
            end
        end
    end
end

@testset "a malformed error object is a protocol error" begin
    # A non-integer code used to be silently rewritten to ERR_INTERNAL, which
    # reports a different error than the one the server sent.
    for err_obj in (Dict("code" => -32602, "message" => 5),
                    Dict("code" => "not a number", "message" => "m"),
                    Dict("code" => -3.5, "message" => "m"))
        with_server((fs, msg, req) -> begin
            msg === nothing && return nothing
            get(msg, "method", "") == "tools/call" ?
                json_response(Dict("jsonrpc" => "2.0", "id" => msg["id"], "error" => err_obj)) :
                default_dispatch(fs, msg, req)
        end) do fs
            Client(fs.url; timeout = 5) do client
                err = try
                    call_tool(client, "echo", Dict{String,Any}())
                    nothing
                catch e
                    e
                end
                @test err isa MCPProtocolError
            end
        end
    end
    # An integer-valued float is a JSON round-trip artefact and still works.
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        get(msg, "method", "") == "tools/call" ?
            json_response(Dict("jsonrpc" => "2.0", "id" => msg["id"],
                               "error" => Dict("code" => -32602.0, "message" => "bad args"))) :
            default_dispatch(fs, msg, req)
    end) do fs
        Client(fs.url; timeout = 5) do client
            err = try
                call_tool(client, "echo", Dict{String,Any}())
                nothing
            catch e
                e
            end
            @test err isa JSONRPCError
            @test err.code == -32602
        end
    end
end

@testset "a wrong-typed capabilities object is not silently emptied" begin
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        get(msg, "method", "") == "initialize" || return default_dispatch(fs, msg, req)
        json_response(result_for(msg, Dict("protocolVersion" => LATEST_PROTOCOL_VERSION,
                                          "capabilities" => [1, 2],
                                          "serverInfo" => Dict("name" => "s", "version" => "1"))))
    end) do fs
        @test_throws MCPProtocolError Client(fs.url; timeout = 5)
    end
end

@testset "close wakes a request that is still in flight" begin
    # The HTTP transport used to close its socket without touching the waiter, so
    # the caller sat out its whole deadline after close() had returned. The stdio
    # transport already did this correctly; the two must agree.
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        get(msg, "method", "") == "tools/call" ? (sleep(30); json_response(result_for(msg, Dict()))) :
            default_dispatch(fs, msg, req)
    end) do fs
        client = Client(fs.url; timeout = 60)
        outcome = Ref{Any}(nothing)
        caller = @async begin
            outcome[] = try
                call_tool(client, "slow", Dict{String,Any}())
            catch e
                e
            end
        end
        # Let the POST get out before closing, otherwise this tests the
        # already-closed path instead.
        sleep(1.0)
        started = time()
        close(client)
        wait(caller)
        elapsed = time() - started
        @test outcome[] isa MCPTransportError
        # Comfortably under both the 60s deadline and the server's 30s sleep.
        @test elapsed < 15
    end
end

@testset "a request sent after close fails immediately" begin
    with_server() do fs
        client = Client(fs.url; timeout = 5)
        close(client)
        @test_throws MCPTransportError ping(client)
    end
end

@testset "a handshake failure closes a transport it was handed" begin
    # The URL and Cmd constructors guarded this; the transport-taking one, which
    # the docstring recommends for further configuration, did not.
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        get(msg, "method", "") == "initialize" ?
            json_response(error_for(msg, -32603, "no handshake for you")) :
            default_dispatch(fs, msg, req)
    end) do fs
        transport = StreamableHTTPTransport(fs.url; timeout = 5)
        @test_throws JSONRPCError Client(transport)
        @test !MCPClient.is_open(transport)

        # And the do-block form, whose construction sits outside its own try.
        other = StreamableHTTPTransport(fs.url; timeout = 5)
        @test_throws JSONRPCError Client(c -> c, other)
        @test !MCPClient.is_open(other)
    end
end

@testset "server-initiated requests are bounded" begin
    # A server that answers every POST with a request used to get an unbounded
    # reply loop: each reply is a POST whose own body is routed back in.
    answered = Threads.Atomic{Int}(0)
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        method = get(msg, "method", "")
        if method == "initialize" || startswith(method, "notifications/")
            return default_dispatch(fs, msg, req)
        end
        # Every message the client sends, reply or not, provokes another request.
        Threads.atomic_add!(answered, 1)
        return json_response(Dict("jsonrpc" => "2.0", "id" => "srv-$(answered[])", "method" => "ping"))
    end) do fs
        client = Client(fs.url; timeout = 5)
        try
            # Enough to prove it terminates rather than growing without bound;
            # the budget itself is 10_000, which is too slow to drive here.
            sleep(2.0)
            @test client.answered <= MCPClient.MAX_ANSWERED_REQUESTS
        finally
            close(client)
        end
    end
end

@testset "a notification handler may call back into the client" begin
    # Handlers used to run on the reader task, so a handler that called the
    # client deadlocked the transport it was waiting on.
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        if get(msg, "method", "") == "tools/call"
            return sse_response(
                Dict("jsonrpc" => "2.0", "method" => "notifications/progress",
                     "params" => Dict("progressToken" => "t", "progress" => 1)),
                result_for(msg, text_tool_result("done")))
        end
        return default_dispatch(fs, msg, req)
    end) do fs
        pinged = Threads.Atomic{Int}(0)
        client = Client(fs.url; timeout = 10, on_notification = function (_)
            # A nested call on the same client: this is the deadlock case.
            try
                ping(client)
                Threads.atomic_add!(pinged, 1)
            catch
            end
        end)
        try
            started = time()
            result = call_tool(client, "echo", Dict{String,Any}("text" => "hi"))
            elapsed = time() - started
            @test content_text(result) == "done"
            # The handler no longer blocks the call it arrived on.
            @test elapsed < 5
            # And the nested ping did get through, on the pump's task.
            timeout = time() + 5
            while pinged[] == 0 && time() < timeout
                sleep(0.05)
            end
            @test pinged[] == 1
        finally
            close(client)
        end
    end
end

@testset "notification handlers run in order and survive a throw" begin
    seen = Int[]
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        if get(msg, "method", "") == "tools/call"
            notes = [Dict("jsonrpc" => "2.0", "method" => "notifications/progress",
                          "params" => Dict("progress" => i)) for i in 1:5]
            return sse_response(notes..., result_for(msg, text_tool_result("ok")))
        end
        return default_dispatch(fs, msg, req)
    end) do fs
        client = Client(fs.url; timeout = 10, on_notification = function (m)
            n = m["params"]["progress"]
            # A throwing handler must not kill the pump for the ones after it.
            n == 2 && error("handler blew up")
            push!(seen, n)
        end)
        try
            call_tool(client, "echo", Dict{String,Any}())
            timeout = time() + 5
            while length(seen) < 4 && time() < timeout
                sleep(0.05)
            end
            @test seen == [1, 3, 4, 5]
        finally
            close(client)
        end
    end
end

@testset "on_request handler answers a server request" begin
    # Previously untested, which is why the answering path went unexercised.
    with_server((fs, msg, req) -> begin
        msg === nothing && return nothing
        method = get(msg, "method", "")
        if method == "tools/call"
            return sse_response(
                Dict("jsonrpc" => "2.0", "id" => "srv-1", "method" => "roots/list"),
                result_for(msg, text_tool_result("ok")))
        end
        # A message with no method is the client's reply to us; 202 is the
        # correct answer, and answering it with an error would provoke another.
        isempty(method) && return nothing
        return default_dispatch(fs, msg, req)
    end) do fs
        asked = Threads.Atomic{Int}(0)
        Client(fs.url; timeout = 10,
               on_request = (method, params) -> begin
                   method == "roots/list" && Threads.atomic_add!(asked, 1)
                   return Dict{String,Any}("roots" => [])
               end) do client
            call_tool(client, "echo", Dict{String,Any}())
            # Wait for the reply to reach the server, not merely for the handler
            # to run: the reply is POSTed after the handler returns.
            replies() = filter(m -> get(m, "id", nothing) == "srv-1", received_messages(fs))
            deadline = time() + 10
            while isempty(replies()) && time() < deadline
                sleep(0.05)
            end
            @test asked[] == 1
            # The reply went back as a result, not as a "method not found" error.
            @test length(replies()) == 1
            @test haskey(replies()[1], "result")
        end
    end
end

@testset "call_tool sends a progress token when asked" begin
    with_server() do fs
        Client(fs.url; timeout = 5) do client
            call_tool(client, "echo", Dict{String,Any}("text" => "x"); progress_token = "tok-1")
            calls = filter(m -> get(m, "method", "") == "tools/call", received_messages(fs))
            @test length(calls) == 1
            @test calls[1]["params"]["_meta"]["progressToken"] == "tok-1"
        end
    end
end

# The stdio transport spawns a real child process, so its fake server is a script
# rather than an in-process handler; see test/stdio.jl.
include("stdio.jl")

end
