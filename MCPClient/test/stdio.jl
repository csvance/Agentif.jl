# Tests for the stdio transport. The fake server is a real child process
# (`stdio_fakeserver.jl`), because everything that is specific to stdio lives in
# the process boundary: pipe framing, a child that dies, a child that logs.

using MCPClient: StdioTransport, send_request!, send_notification!, set_handler!,
                 is_open, stderr_tail, request_message, notification_message

const STDIO_FAKESERVER = joinpath(@__DIR__, "stdio_fakeserver.jl")

# The same julia binary and project as this test process, so the child can load
# JSON without a resolve of its own.
stdio_cmd(mode::AbstractString="plain") =
    `$(Base.julia_cmd()) --startup-file=no --color=no --project=$(Base.active_project()) $STDIO_FAKESERVER $mode`

# Child startup is a whole julia process, so per-request deadlines here are
# generous; the tests that are about a deadline set their own.
const STDIO_TIMEOUT = 60.0

with_stdio_transport(f, mode::AbstractString="plain"; kwargs...) = begin
    t = StdioTransport(stdio_cmd(mode); timeout=STDIO_TIMEOUT, kwargs...)
    try
        f(t)
    finally
        close(t)
    end
end

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

@testset "stdio transport basics" begin
    with_stdio_transport() do t
        @test is_open(t)
        # There is no session and no protocol-version header on stdio.
        @test session_id(t) === nothing
        @test MCPClient.protocol_version!(t, "2025-06-18") === nothing
        @test occursin("StdioTransport", sprint(show, t))

        reply = send_request!(t, request_message(1, "ping", Dict{String,Any}()), 1)
        @test reply["id"] == 1
        @test reply["result"] == Dict{String,Any}()

        # A second request on the same child reuses the same stream.
        reply = send_request!(t, request_message(2, "tools/list", Dict{String,Any}()), 2)
        @test reply["result"]["tools"][1]["name"] == "echo"

        # A string id round-trips as well as a numeric one.
        reply = send_request!(t, request_message("abc", "ping", Dict{String,Any}()), "abc")
        @test reply["id"] == "abc"
    end
end

@testset "stdio notifications in both directions" begin
    with_stdio_transport() do t
        seen = Any[]
        lk = ReentrantLock()
        set_handler!(t, m -> @lock lk push!(seen, m))

        @test send_notification!(t, notification_message("notifications/initialized", nothing)) === nothing
        # The fake server acknowledges every notification with one of its own, so
        # a message that arrives with nothing waiting for it still reaches the
        # handler rather than being dropped.
        @test wait_until(() -> any(m -> get(m, "method", "") == "notifications/ack" &&
                                       m["params"]["of"] == "notifications/initialized",
                                  @lock lk copy(seen)))
    end
end

@testset "a server notification arriving mid-request reaches the handler" begin
    with_stdio_transport() do t
        seen = Any[]
        lk = ReentrantLock()
        set_handler!(t, m -> @lock lk push!(seen, m))
        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "notify_then_answer",
                                                   "arguments" => Dict{String,Any}()))
        reply = send_request!(t, message, 1)
        @test reply["result"]["content"][1]["text"] == "answered after notifying"
        # The reader dispatches in stream order, so the notification is already in
        # hand by the time the response returns. Nothing on the stream is dropped
        # while a request is outstanding.
        notes = @lock lk copy(seen)
        @test length(notes) == 1
        @test notes[1]["method"] == "notifications/message"
        @test notes[1]["params"]["data"] == "working on it"
    end
end

@testset "concurrent stdio requests answered out of order" begin
    with_stdio_transport() do t
        finished = String[]
        lk = ReentrantLock()
        slow = @async begin
            reply = send_request!(t, request_message(1, "tools/call",
                Dict{String,Any}("name" => "delay",
                                 "arguments" => Dict{String,Any}("seconds" => 1.0))), 1)
            @lock lk push!(finished, "slow")
            reply
        end
        # Give the slow request time to be written before the fast one follows it.
        sleep(0.2)
        # Reusing an id while the first request is still outstanding is refused
        # rather than quietly stealing the earlier caller's response.
        @test_throws MCPProtocolError send_request!(t, request_message(1, "ping", Dict{String,Any}()), 1)
        fast = @async begin
            reply = send_request!(t, request_message(2, "tools/call",
                Dict{String,Any}("name" => "echo",
                                 "arguments" => Dict{String,Any}("text" => "quick"))), 2)
            @lock lk push!(finished, "fast")
            reply
        end
        slow_reply = fetch(slow)
        fast_reply = fetch(fast)
        # Each caller got its own response, matched by id and not by arrival order.
        @test slow_reply["id"] == 1
        @test occursin("waited", slow_reply["result"]["content"][1]["text"])
        @test fast_reply["id"] == 2
        @test fast_reply["result"]["content"][1]["text"] == "quick"
        @test finished == ["fast", "slow"]
    end
end

@testset "a stdio request that is never answered times out" begin
    with_stdio_transport() do t
        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "slow",
                                                   "arguments" => Dict{String,Any}()))
        elapsed = @elapsed err = try
            send_request!(t, message, 1; timeout=0.5)
            nothing
        catch e
            e
        end
        @test err isa MCPTimeoutError
        @test err.method == "tools/call"
        @test err.timeout == 0.5
        @test elapsed < 10

        # The waiter is gone, so nothing is left holding the id.
        @test isempty(getfield(t, :pending))

        # The transport survives: the child is still there and still serving.
        @test is_open(t)
        reply = send_request!(t, request_message(2, "ping", Dict{String,Any}()), 2)
        @test reply["result"] == Dict{String,Any}()
    end
end

@testset "a child that dies mid-request fails its callers" begin
    t = StdioTransport(stdio_cmd(); timeout=STDIO_TIMEOUT)
    try
        # Warm the child up, so the failure below is unambiguously the exit and
        # not a child that never started.
        send_request!(t, request_message(0, "ping", Dict{String,Any}()), 0)

        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "die_loudly",
                                                   "arguments" => Dict{String,Any}()))
        # Well under the transport's own timeout: a dead child must not be
        # indistinguishable from a slow one.
        elapsed = @elapsed err = try
            send_request!(t, message, 1)
            nothing
        catch e
            e
        end
        @test err isa MCPTransportError
        @test elapsed < 15
        @test occursin("exited with code 9", err.message)
        # The child's own explanation is quoted, which is the only thing it left.
        @test occursin("giving up", err.message)
        @test occursin("giving up", join(stderr_tail(t), "\n"))

        # And the transport knows it is unusable rather than trying again.
        @test !is_open(t)
        @test_throws MCPTransportError send_request!(t, request_message(2, "ping", Dict{String,Any}()), 2)
        @test_throws MCPTransportError send_notification!(t, notification_message("notifications/x", nothing))
    finally
        close(t)
    end

    # Several waiters at once all fail, none is left hanging.
    t = StdioTransport(stdio_cmd(); timeout=STDIO_TIMEOUT)
    try
        send_request!(t, request_message(0, "ping", Dict{String,Any}()), 0)
        waiters = [@async(try
                              send_request!(t, request_message(i, "tools/call",
                                  Dict{String,Any}("name" => "delay",
                                                   "arguments" => Dict{String,Any}("seconds" => 20))), i)
                          catch e
                              e
                          end) for i in 1:3]
        sleep(0.3)
        try
            send_request!(t, request_message(9, "tools/call",
                Dict{String,Any}("name" => "die", "arguments" => Dict{String,Any}())), 9)
        catch
        end
        results = fetch.(waiters)
        @test all(r -> r isa MCPTransportError, results)
    finally
        close(t)
    end
end

@testset "garbage on stdout does not kill the session" begin
    with_stdio_transport() do t
        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "noise",
                                                   "arguments" => Dict{String,Any}()))
        reply = send_request!(t, message, 1)
        @test reply["result"]["content"][1]["text"] == "survived the noise"
        # And the stream is still usable afterwards.
        @test send_request!(t, request_message(2, "ping", Dict{String,Any}()), 2)["result"] == Dict{String,Any}()
    end

    # Noise before the handshake, which is what a server printing a banner does.
    client = Client(stdio_cmd("banner"); timeout=STDIO_TIMEOUT)
    try
        @test server_info(client)["name"] == "fake-stdio-mcp"
    finally
        close(client)
    end
end

@testset "stderr is a log stream, never protocol" begin
    with_stdio_transport() do t
        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "log",
                                                   "arguments" => Dict{String,Any}()))
        reply = send_request!(t, message, 1)
        # The server wrote a well-formed response for id 1 on stderr as well. The
        # one that counts is the one that came from stdout.
        @test reply["result"]["content"][1]["text"] == "from stdout"
        @test wait_until(() -> occursin("plain log line", join(stderr_tail(t), "\n")))
    end

    # A server that logs heavily before reading anything: without a drain it
    # blocks on a full pipe buffer and the handshake never completes.
    client = Client(stdio_cmd("noisy"); timeout=STDIO_TIMEOUT)
    try
        @test server_info(client)["name"] == "fake-stdio-mcp"
        # The kept tail is bounded, not the whole 4000-line flood.
        @test length(stderr_tail(client.transport)) <= 50
        @test !isempty(stderr_tail(client.transport))
    finally
        close(client)
    end
end

@testset "a response nobody is waiting for is ignored" begin
    with_stdio_transport() do t
        message = request_message(1, "tools/call",
                                  Dict{String,Any}("name" => "orphan",
                                                   "arguments" => Dict{String,Any}()))
        @test send_request!(t, message, 1)["result"]["content"][1]["text"] == "orphan ignored"
    end
end

@testset "close reaps the child and is idempotent" begin
    t = StdioTransport(stdio_cmd(); timeout=STDIO_TIMEOUT)
    process = getfield(t, :process)
    send_request!(t, request_message(1, "ping", Dict{String,Any}()), 1)
    @test Base.process_running(process)
    close(t)
    @test !Base.process_running(process)
    @test !is_open(t)
    close(t)  # idempotent
    @test_throws MCPTransportError send_request!(t, request_message(2, "ping", Dict{String,Any}()), 2)

    # A child that ignores both stdin EOF and SIGTERM still gets reaped, because
    # close escalates rather than waiting on a process that will never leave.
    if Sys.which("bash") !== nothing
        stubborn = StdioTransport(`bash -c 'trap "" TERM; while true; do sleep 0.2; done'`;
                                  close_grace=0.4)
        stubborn_process = getfield(stubborn, :process)
        @test Base.process_running(stubborn_process)
        elapsed = @elapsed close(stubborn)
        @test !Base.process_running(stubborn_process)
        @test elapsed < 10
    end

    # A command that cannot be started is a transport failure, not a crash.
    @test_throws MCPTransportError StdioTransport(`/nonexistent/mcp-server-binary`)
end

@testset "stdio environment and working directory" begin
    # `env` adds to the environment this process has, because a server started
    # through npx or uvx needs PATH and HOME to survive.
    withenv("MCP_STDIO_INHERITED" => "yes") do
        with_stdio_transport(; env=Dict("MCP_STDIO_ADDED" => "added")) do t
            ask = function (name)
                message = request_message(1, "tools/call",
                    Dict{String,Any}("name" => "env",
                                     "arguments" => Dict{String,Any}("name" => name)))
                send_request!(t, message, 1)["result"]["content"][1]["text"]
            end
            @test ask("MCP_STDIO_ADDED") == "added"
            @test ask("MCP_STDIO_INHERITED") == "yes"
        end

        # inherit_env=false hands the child only what it was given. The child here
        # is another julia, so it still needs the few variables that let it find
        # its depot; a real server is given whatever it documents.
        minimal = Dict{String,String}("MCP_STDIO_ADDED" => "added")
        for name in ("PATH", "HOME", "JULIA_DEPOT_PATH", "JULIA_LOAD_PATH", "LANG")
            haskey(ENV, name) && (minimal[name] = ENV[name])
        end
        with_stdio_transport(; env=minimal, inherit_env=false) do t
            ask = function (name)
                message = request_message(1, "tools/call",
                    Dict{String,Any}("name" => "env",
                                     "arguments" => Dict{String,Any}("name" => name)))
                send_request!(t, message, 1)["result"]["content"][1]["text"]
            end
            @test ask("MCP_STDIO_ADDED") == "added"
            @test ask("MCP_STDIO_INHERITED") == ""
        end
    end

    dir = mktempdir()
    try
        with_stdio_transport(; dir=dir) do t
            message = request_message(1, "tools/call",
                Dict{String,Any}("name" => "cwd", "arguments" => Dict{String,Any}()))
            reported = send_request!(t, message, 1)["result"]["content"][1]["text"]
            # realpath on both sides: a temporary directory is often behind a symlink.
            @test realpath(reported) == realpath(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

@testset "a full Client handshake over stdio" begin
    notes = Any[]
    client = Client(stdio_cmd(); timeout=STDIO_TIMEOUT,
                    on_notification=m -> push!(notes, m))
    try
        @test server_info(client)["name"] == "fake-stdio-mcp"
        @test server_info(client)["version"] == "9.9.9"
        @test protocol_version(client) == LATEST_PROTOCOL_VERSION
        @test server_instructions(client) == "be brief"
        @test has_capability(client, "tools")
        @test !has_capability(client, "prompts")
        # Nothing on stdio carries a session.
        @test session_id(client) === nothing
        @test is_open(client)

        tools = list_tools(client)
        @test [tool.name for tool in tools] == ["echo"]
        @test tools[1].description == "Echo text back"

        @test content_text(call_tool(client, "echo", Dict{String,Any}("text" => "hi there"))) == "hi there"
        @test ping(client) === nothing

        # A rejected request is a typed exception and the session survives it.
        err = try
            call_tool(client, "nope")
            nothing
        catch e
            e
        end
        @test err isa JSONRPCError
        @test err.code == -32602
        @test err.data["tool"] == "nope"
        @test content_text(call_tool(client, "echo", Dict{String,Any}("text" => "still here"))) == "still here"

        # The handshake's own notification was sent, which the server echoes back.
        @test wait_until(() -> any(m -> get(m, "method", "") == "notifications/ack" &&
                                       m["params"]["of"] == "notifications/initialized", notes))

        # A raw request for a method this package does not wrap.
        @test request(client, "ping", Dict{String,Any}()) == Dict{String,Any}()
    finally
        close(client)
    end

    # The do-block form closes the client, and the child with it.
    transport = StdioTransport(stdio_cmd(); timeout=STDIO_TIMEOUT)
    process = getfield(transport, :process)
    result = Client(transport) do c
        content_text(call_tool(c, "echo", Dict{String,Any}("text" => "scoped")))
    end
    @test result == "scoped"
    @test !Base.process_running(process)

    # A command that is not an MCP server at all fails the handshake and does not
    # leave the child behind.
    @test_throws MCPException Client(`$(Base.julia_cmd()) --startup-file=no -e 'exit(0)'`;
                                     timeout=10)
end

@testset "a server-initiated request over stdio is answered" begin
    with_stdio_transport() do t
        client = Client(t; timeout=STDIO_TIMEOUT)
        @test content_text(call_tool(client, "ask_then_answer")) == "answered after asking"
        # The client answers the server's ping by writing a response line back to
        # the same stdin; the fake server logs what it received.
        @test wait_until(() -> occursin("srv-1", join(stderr_tail(t), "\n")))
        @test occursin("client replied", join(stderr_tail(t), "\n"))
    end
end
