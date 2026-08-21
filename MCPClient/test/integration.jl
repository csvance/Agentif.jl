# Integration tests against a real MCP server.
#
# The rest of the suite talks to fakes, which is what makes it fast and offline,
# but a fake only ever behaves the way its author believed a server behaves. These
# tests run the reference implementation, `@modelcontextprotocol/server-everything`,
# over both transports, so the same assertions cover a real child process speaking
# newline-delimited JSON and a real HTTP endpoint answering with SSE, a session id
# and chunked framing.
#
# They need `npx` and network access on the first run, so they are opt-in:
#
#     MCPCLIENT_INTEGRATION=1 julia --project=. test/runtests.jl
#
# `MCPCLIENT_EVERYTHING` overrides the npm specifier, which is pinned so a change
# to the reference server's tool names cannot silently change what is tested.

using Test
using MCPClient
using MCPClient: SUPPORTED_PROTOCOL_VERSIONS
using HTTP, JSON, Sockets

const EVERYTHING_PKG = get(
    ENV, "MCPCLIENT_EVERYTHING",
    "@modelcontextprotocol/server-everything@2026.7.4"
)

# The first `npx` run may fetch the package, and the reference server takes a
# moment to come up under Node, so the deadlines here are far looser than the
# 30 seconds a warm call needs.
const INTEGRATION_TIMEOUT = 60.0

everything_stdio_cmd() = `npx -y $EVERYTHING_PKG stdio`

"""
    poll_until(predicate; seconds) -> Bool

Poll rather than sleep a fixed amount: everything here crosses a process
boundary, so the only safe wait is one that ends when the condition holds. Named
apart from `fakeserver.jl`'s equivalent so this file can also be run on its own.
"""
function poll_until(predicate; seconds::Real = 10.0)
    deadline = time() + seconds
    while time() < deadline
        predicate() && return true
        sleep(0.05)
    end
    return predicate()
end


"""
    free_port() -> Int

A port that was free a moment ago. There is no way to hand a listening socket to
a child process that opens its own, so this races in principle; in practice the
window is microseconds and the alternative is a hard-coded port that collides
with whatever else is on the host.
"""
function free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Sockets.getsockname(server)[2]
    close(server)
    return Int(port)
end

"""
    with_http_server(f)

Run the reference server in streamable-HTTP mode on a free port, wait until it
answers, and hand `f` the endpoint URL. The child is killed on the way out
whether or not `f` throws, because a leaked Node process holds the port for the
next run.
"""
function with_http_server(f)
    port = free_port()
    cmd = Cmd(`npx -y $EVERYTHING_PKG streamableHttp`; env = merge(ENV, Dict("PORT" => string(port))))
    process = open(pipeline(cmd; stdout = devnull, stderr = devnull), "r")
    url = "http://127.0.0.1:$port/mcp"
    return try
        # Poll the endpoint rather than sleeping a fixed amount: startup time
        # depends on whether npm has the package cached.
        ready = poll_until(seconds = INTEGRATION_TIMEOUT) do
            process_exited(process) && error("the reference MCP server exited before it listened")
            try
                # An empty POST is enough to prove something is listening and
                # speaking HTTP; the status it answers with does not matter.
                HTTP.post(
                    url, ["Content-Type" => "application/json"], "{}";
                    status_exception = false, retry = false, request_timeout = 2
                )
                true
            catch
                false
            end
        end
        ready || error("the reference MCP server did not listen on $port within $INTEGRATION_TIMEOUT s")
        f(url)
    finally
        try
            kill(process)
        catch
        end
    end
end

# --- assertions shared by both transports ---------------------------------
#
# Every one of these is transport independent by design: the protocol layer is
# shared, so anything that passes over stdio and fails over HTTP (or the reverse)
# is a transport bug, which is exactly what running the same body twice finds.

function check_handshake(client)
    @test protocol_version(client) in SUPPORTED_PROTOCOL_VERSIONS
    info = server_info(client)
    @test info isa Dict{String, Any}
    @test !isempty(get(info, "name", ""))
    @test has_capability(client, "tools")
    # The reference server ships instructions; a server that sends none is
    # allowed to, so only the type is asserted for certain.
    instructions = server_instructions(client)
    @test instructions === nothing || instructions isa String
    @test instructions !== nothing && !isempty(instructions)
    @test is_open(client)
    return @test occursin("Client(", sprint(show, client))
end

function check_list_tools(client)
    tools = list_tools(client)
    @test !isempty(tools)
    for tool in tools
        @test tool isa MCPTool
        @test !isempty(tool.name)
        # Every tool the client will ever offer a model needs an arguments schema
        # it can render, and `MCPTool` promises a plain object even when the
        # server omitted one.
        @test tool.input_schema isa Dict{String, Any}
        @test get(tool.input_schema, "type", "object") == "object"
        @test tool.description isa String
    end
    names = [t.name for t in tools]
    @test "echo" in names
    return tools
end

function check_text_tool(client)
    result = call_tool(client, "echo", Dict{String, Any}("message" => "hello from Julia"))
    @test result isa ToolResult
    @test !result.is_error
    @test occursin("hello from Julia", content_text(result))
    @test any(b isa TextContent for b in result.content)
    # A NamedTuple is the other accepted argument form, and it has to reach the
    # server as the same object.
    named = call_tool(client, "echo", (message = "named tuple",))
    return @test occursin("named tuple", content_text(named))
end

function check_numeric_arguments(client)
    # Numbers must survive as JSON numbers: a client that stringifies them gets a
    # validation error from a schema-checking server, which this one is.
    result = call_tool(client, "get-sum", Dict{String, Any}("a" => 17, "b" => 25))
    @test !result.is_error
    return @test occursin("42", content_text(result))
end

function check_image_content(client)
    result = call_tool(client, "get-tiny-image")
    @test !result.is_error
    images = [b for b in result.content if b isa ImageContent]
    @test length(images) == 1
    image = only(images)
    @test !isempty(image.data)
    # Decoded, not still base64: the first bytes are the PNG signature.
    @test image.data[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]
    @test startswith(image.mime_type, "image/")
    # The original base64 stays reachable, and an image contributes no text.
    @test image.raw["data"] isa String
    return @test content_text(image) == ""
end

function check_embedded_resource(client)
    result = call_tool(
        client, "get-resource-reference",
        Dict{String, Any}("resourceType" => "Text", "resourceId" => 1)
    )
    @test !result.is_error
    resources = [b for b in result.content if b isa EmbeddedResource]
    @test length(resources) == 1
    resource = only(resources)
    @test !isempty(resource.uri)
    # Exactly one of text and blob, per the spec, and the text form here.
    @test resource.text !== nothing
    @test resource.blob === nothing
    # An embedded resource's text is part of what a model should see.
    return @test occursin(resource.text, content_text(result))
end

function check_resource_links(client)
    result = call_tool(client, "get-resource-links", Dict{String, Any}("count" => 2))
    @test !result.is_error
    links = [b for b in result.content if b isa ResourceLink]
    @test length(links) == 2
    for link in links
        @test !isempty(link.uri)
        @test !isempty(link.name)
        # A link carries no contents, so it contributes nothing to the text.
        @test content_text(link) == ""
    end
    return
end

function check_structured_content(client)
    tool = only(t for t in list_tools(client) if t.name == "get-structured-content")
    @test tool.output_schema isa Dict{String, Any}
    result = call_tool(client, "get-structured-content", Dict{String, Any}("location" => "Chicago"))
    @test !result.is_error
    @test result.structured_content isa Dict{String, Any}
    @test haskey(result.structured_content, "temperature")
    # A server that declares an output schema still sends the text form too.
    return @test !isempty(content_text(result))
end

function check_tool_failure_is_data(client)
    # This server reports an unknown tool as a failed result rather than as a
    # JSON-RPC error, which is the case a caller is most likely to mishandle:
    # the call happened, the tool did not.
    result = call_tool(client, "no-such-tool-exists")
    @test result isa ToolResult
    @test result.is_error
    @test !isempty(content_text(result))

    # Bad arguments against a schema-checking server, same shape.
    invalid = call_tool(
        client, "get-structured-content",
        Dict{String, Any}("location" => "Atlantis")
    )
    return @test invalid.is_error
end

function check_unknown_method_is_an_exception(client)
    # An unknown *method*, unlike an unknown tool, is a protocol-level rejection.
    err = try
        request(client, "no/such/method", Dict{String, Any}())
        nothing
    catch e
        e
    end
    @test err isa JSONRPCError
    @test err.method == "no/such/method"
    @test err.code == -32601
    return @test occursin("no/such/method", sprint(showerror, err))
end

function check_raw_request(client)
    # Methods this package does not wrap have to stay reachable, and the values
    # they return have to be plain containers.
    resources = request(client, "resources/list", Dict{String, Any}())
    @test resources isa Dict{String, Any}
    @test get(resources, "resources", nothing) isa Vector{Any}
    prompts = request(client, "prompts/list", Dict{String, Any}())
    @test prompts isa Dict{String, Any}
    return @test get(prompts, "prompts", nothing) isa Vector{Any}
end

function check_concurrent_calls(client)
    # Ten calls in flight at once, each with a distinct answer. This is the test
    # that fails when responses are correlated wrongly: over stdio every reply
    # arrives on one shared stream, and the server answers them out of order.
    # Zero-padded so no label is a prefix of another: the cross-talk assertion
    # below is a substring test, and "concurrent-1" occurs inside "concurrent-10".
    inputs = ["concurrent-" * lpad(i, 2, '0') for i in 1:10]
    results = Vector{Any}(undef, length(inputs))
    @sync for (i, text) in enumerate(inputs)
        @async results[i] = call_tool(client, "echo", Dict{String, Any}("message" => text))
    end
    for (i, text) in enumerate(inputs)
        @test !results[i].is_error
        @test occursin(text, content_text(results[i]))
        # The decisive assertion: no reply landed on the wrong caller.
        for other in inputs
            other == text && continue
            @test !occursin(other, content_text(results[i]))
        end
    end
    return
end

function check_timeout_then_recovery(client)
    # A tool that runs far past the deadline. The call must give up on time, and
    # the session must still be usable afterwards: a client that leaves the
    # transport wedged after one slow tool is unusable in practice.
    started = time()
    err = try
        call_tool(
            client, "trigger-long-running-operation",
            Dict{String, Any}("duration" => 30, "steps" => 30); timeout = 1.0
        )
        nothing
    catch e
        e
    end
    elapsed = time() - started
    @test err isa MCPTimeoutError
    @test err.method == "tools/call"
    @test elapsed < 15    # gave up on the deadline, not on the tool
    @test is_open(client)
    # The transport still works, and the abandoned call's reply does not come
    # back as the answer to this one.
    @test ping(client) === nothing
    recovered = call_tool(client, "echo", Dict{String, Any}("message" => "still here"))
    return @test occursin("still here", content_text(recovered))
end

function check_close_is_idempotent(client)
    @test is_open(client)
    close(client)
    @test !is_open(client)
    @test close(client) === nothing
    # A closed client refuses work rather than hanging.
    return @test_throws MCPException ping(client)
end

# `progress_token` and `on_notification` need a client built with a handler, so
# this takes the factory rather than a live client.
function check_progress_notifications(connect)
    seen = Channel{Any}(Inf)
    return connect(on_notification = msg -> put!(seen, msg)) do client
        result = call_tool(
            client, "trigger-long-running-operation",
            Dict{String, Any}("duration" => 1, "steps" => 4);
            timeout = INTEGRATION_TIMEOUT, progress_token = "tok-1"
        )
        @test !result.is_error
        # The notifications race the response, so wait for them rather than
        # asserting on whatever happened to have arrived.
        @test poll_until(() -> Base.n_avail(seen) > 0, seconds = 10.0)
        close(seen)
        messages = collect(seen)
        progress = [m for m in messages if get(m, "method", "") == "notifications/progress"]
        @test !isempty(progress)
        for note in progress
            params = note["params"]
            @test params["progressToken"] == "tok-1"
            @test haskey(params, "progress")
        end
    end
end

# --- the two transports ---------------------------------------------------

"""
    run_shared_tests(connect, label)

`connect(f; kwargs...)` opens a client against one transport and closes it after
`f`. Every assertion below runs against both, because the protocol layer they
share is where a bug would be invisible to a one-transport suite.
"""
function run_shared_tests(connect, label)
    @testset "$label: handshake" begin
        connect(check_handshake)
    end
    @testset "$label: tools/list" begin
        connect(check_list_tools)
    end
    @testset "$label: content blocks" begin
        connect() do client
            check_text_tool(client)
            check_numeric_arguments(client)
            check_image_content(client)
            check_embedded_resource(client)
            check_resource_links(client)
            check_structured_content(client)
        end
    end
    @testset "$label: failures" begin
        connect() do client
            check_tool_failure_is_data(client)
            check_unknown_method_is_an_exception(client)
        end
    end
    @testset "$label: unwrapped methods" begin
        connect(check_raw_request)
    end
    @testset "$label: concurrent calls" begin
        connect(check_concurrent_calls)
    end
    @testset "$label: timeout and recovery" begin
        connect(check_timeout_then_recovery)
    end
    @testset "$label: progress notifications" begin
        check_progress_notifications(connect)
    end
    return @testset "$label: close" begin
        # Not wrapped in `connect`: closing is the subject, and a second close
        # from the wrapper is itself part of what is asserted.
        connect(check_close_is_idempotent)
    end
end

@testset "integration: real MCP server over stdio" begin
    connect(f; kwargs...) = Client(
        f, everything_stdio_cmd();
        timeout = INTEGRATION_TIMEOUT, kwargs...
    )
    run_shared_tests(connect, "stdio")

    @testset "stdio specifics" begin
        connect() do client
            # There is no session on stdio, and the transport is a child process.
            @test session_id(client) === nothing
            @test client.transport isa StdioTransport
            @test isempty(MCPClient.stderr_tail(client.transport)) ||
                MCPClient.stderr_tail(client.transport) isa Vector{String}
        end
    end

    @testset "server notifications outside a response do arrive over stdio" begin
        # The contrast to the HTTP case above: one shared stream carries the
        # server's own traffic whether or not a request is outstanding.
        seen = Channel{Any}(Inf)
        Client(
            everything_stdio_cmd(); timeout = INTEGRATION_TIMEOUT,
            on_notification = msg -> put!(seen, msg)
        ) do client
            logging = call_tool(client, "toggle-simulated-logging")
            @test !logging.is_error
            @test poll_until(() -> Base.n_avail(seen) > 0, seconds = 15.0)
            close(seen)
            methods_seen = unique(get(m, "method", "") for m in collect(seen))
            @test "notifications/message" in methods_seen
        end
    end

    @testset "closing a stdio client reaps the child" begin
        client = Client(everything_stdio_cmd(); timeout = INTEGRATION_TIMEOUT)
        process = client.transport.process
        @test !process_exited(process)
        close(client)
        # The escalation in `close` ends with SIGKILL, so this must hold without
        # any further waiting.
        @test process_exited(process)
    end

    @testset "a command that is not an MCP server fails cleanly" begin
        # `true` exits immediately, having answered nothing: the handshake has to
        # fail with a transport error rather than hang for the whole deadline.
        started = time()
        @test_throws MCPTransportError Client(`sh -c "exit 0"`; timeout = 10.0)
        @test time() - started < 10
    end
end

@testset "integration: real MCP server over streamable HTTP" begin
    with_http_server() do url
        connect(f; kwargs...) = Client(f, url; timeout = INTEGRATION_TIMEOUT, kwargs...)
        run_shared_tests(connect, "http")

        @testset "http specifics" begin
            connect() do client
                # The server issues a session id, and the client has to have
                # captured it from the initialize response headers.
                sid = session_id(client)
                @test sid isa String
                @test !isempty(sid)
                @test client.transport isa StreamableHTTPTransport
                # It also has to keep working, which only happens if the id and
                # the negotiated protocol version ride along on later requests.
                @test ping(client) === nothing
                @test session_id(client) == sid
            end
        end

        @testset "server notifications outside a response never arrive" begin
            # A known limitation, pinned here so it cannot change unnoticed. The
            # spec lets a server push notifications on a standalone `GET` SSE
            # stream, and the reference server uses it for its log and
            # list_changed traffic. This client never opens that stream, so over
            # HTTP only notifications the server interleaves into a POST's own
            # response body are seen -- progress for the call that asked for it.
            # The same tool over stdio does deliver them, which is what makes
            # this a transport gap rather than a server quirk.
            seen = Channel{Any}(Inf)
            connect(on_notification = msg -> put!(seen, msg)) do client
                logging = call_tool(client, "toggle-simulated-logging")
                @test !logging.is_error
                # The server logs on a several-second cadence; wait past it.
                poll_until(() -> Base.n_avail(seen) > 0, seconds = 8.0)
                @test Base.n_avail(seen) == 0
                # The session is unaffected: nothing is being dropped on the
                # floor mid-stream, there is simply no stream to read.
                @test ping(client) === nothing
            end
        end

        @testset "a session that ends is not silently reused" begin
            client = Client(url; timeout = INTEGRATION_TIMEOUT)
            sid = session_id(client)
            @test sid isa String
            close(client)
            # `close` sends the spec's DELETE, so a fresh client gets a new
            # session rather than inheriting the closed one.
            second = Client(url; timeout = INTEGRATION_TIMEOUT)
            try
                @test session_id(second) != sid
            finally
                close(second)
            end
        end

        @testset "a URL with no MCP server behind it fails cleanly" begin
            dead = "http://127.0.0.1:$(free_port())/mcp"
            @test_throws MCPTransportError Client(dead; timeout = 5.0)
        end
    end
end
