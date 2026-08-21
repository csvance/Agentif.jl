# A fake MCP server that speaks newline-delimited JSON-RPC over stdin and stdout,
# so the stdio tests run offline. Unlike `fakeserver.jl` this is not included by
# the test process: it is a script the test spawns as a child, because a stdio
# transport's whole subject is a child process and an in-process fake would test
# none of it.
#
# The first argument is a startup mode; every other behaviour is selected by the
# name of the tool the client calls, so one script covers every case.
#
#   julia --startup-file=no --project=... stdio_fakeserver.jl [plain|banner|noisy]
#
# Each message is handled on its own task, so a slow reply does not hold up the
# ones behind it. That is what makes responses arrive out of order, which is the
# case a client is most likely to get wrong.

using JSON

const MODE = isempty(ARGS) ? "plain" : ARGS[1]
const OUT_LOCK = ReentrantLock()

send(msg) = @lock OUT_LOCK begin
    println(stdout, JSON.json(msg))
    flush(stdout)
end

# Written straight to stdout, bypassing `send`: the point is that it is not JSON.
raw(line) = @lock OUT_LOCK begin
    println(stdout, line)
    flush(stdout)
end

result(id, r) = Dict("jsonrpc" => "2.0", "id" => id, "result" => r)
text_result(id, text; is_error = false) =
    result(
    id, Dict(
        "content" => [Dict("type" => "text", "text" => text)],
        "isError" => is_error
    )
)

const INITIALIZE_RESULT = Dict(
    "protocolVersion" => "2025-06-18",
    "capabilities" => Dict("tools" => Dict("listChanged" => true)),
    "serverInfo" => Dict("name" => "fake-stdio-mcp", "version" => "9.9.9"),
    "instructions" => "be brief"
)

const TOOLS = [
    Dict(
        "name" => "echo", "description" => "Echo text back",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict("text" => Dict("type" => "string"))
        )
    ),
]

function handle_tool_call(id, params)
    name = get(params, "name", "")
    args = get(params, "arguments", Dict())
    if name == "echo"
        send(text_result(id, get(args, "text", "")))
    elseif name == "delay"
        # Answering late is how the out-of-order test gets its ordering.
        sleep(Float64(get(args, "seconds", 0.1)))
        send(text_result(id, "waited $(get(args, "seconds", 0.1))"))
    elseif name == "slow"
        # Answers long after any test's deadline, then keeps serving, so the test
        # can check the transport is still usable after a timeout.
        sleep(30)
        send(text_result(id, "too late"))
    elseif name == "die"
        # No reply, ever: the process is simply gone.
        flush(stdout)
        exit(3)
    elseif name == "die_loudly"
        println(stderr, "fatal: the server is giving up")
        flush(stderr)
        exit(9)
    elseif name == "noise"
        raw("this line is not JSON at all")
        raw("{\"jsonrpc\": truncated")
        send(text_result(id, "survived the noise"))
    elseif name == "log"
        # stderr must never be read as protocol; this writes something that would
        # be a valid response if it were.
        println(stderr, JSON.json(text_result(id, "this came from stderr")))
        println(stderr, "plain log line")
        flush(stderr)
        send(text_result(id, "from stdout"))
    elseif name == "notify_then_answer"
        send(
            Dict(
                "jsonrpc" => "2.0", "method" => "notifications/message",
                "params" => Dict("level" => "info", "data" => "working on it")
            )
        )
        sleep(0.05)
        send(text_result(id, "answered after notifying"))
    elseif name == "ask_then_answer"
        # A server-initiated request in the middle of answering one of ours.
        send(Dict("jsonrpc" => "2.0", "id" => "srv-1", "method" => "ping"))
        sleep(0.05)
        send(text_result(id, "answered after asking"))
    elseif name == "env"
        send(text_result(id, get(ENV, get(args, "name", ""), "")))
    elseif name == "cwd"
        send(text_result(id, pwd()))
    elseif name == "orphan"
        # A response to an id nobody is waiting for must not disturb the session.
        send(text_result("no-such-id", "nobody asked"))
        send(text_result(id, "orphan ignored"))
    else
        send(
            Dict(
                "jsonrpc" => "2.0", "id" => id,
                "error" => Dict(
                    "code" => -32602, "message" => "Unknown tool: $name",
                    "data" => Dict("tool" => name)
                )
            )
        )
    end
    return nothing
end

function handle(msg)
    method = get(msg, "method", "")
    id = get(msg, "id", nothing)
    if id === nothing
        # A notification. There is nothing to answer, but the test has no other
        # way to see that one arrived, so acknowledge it with a notification of
        # our own rather than adding a side channel.
        send(
            Dict(
                "jsonrpc" => "2.0", "method" => "notifications/ack",
                "params" => Dict("of" => method, "params" => get(msg, "params", nothing))
            )
        )
        return nothing
    end
    if method == "initialize"
        send(result(id, INITIALIZE_RESULT))
    elseif method == "ping"
        send(result(id, Dict()))
    elseif method == "tools/list"
        send(result(id, Dict("tools" => TOOLS)))
    elseif method == "tools/call"
        handle_tool_call(id, get(msg, "params", Dict()))
    elseif method == ""
        # A response from the client to a server-initiated request; log it so the
        # test can see it arrived at all.
        println(stderr, "client replied: ", JSON.json(msg))
        flush(stderr)
    else
        send(
            Dict(
                "jsonrpc" => "2.0", "id" => id,
                "error" => Dict("code" => -32601, "message" => "no such method: $method")
            )
        )
    end
    return nothing
end

if MODE == "banner"
    # The classic broken stdio server: it greets on the protocol stream.
    raw("Fake MCP server listening on stdio")
    raw("{ not json either }")
elseif MODE == "noisy"
    # Enough stderr to fill a pipe buffer several times over. A client that does
    # not drain stderr never gets past this line, and the failure looks exactly
    # like a server that hangs during startup.
    for i in 1:4000
        println(stderr, "startup log line $i ", "x"^80)
    end
    flush(stderr)
end

tasks = Task[]
while !eof(stdin)
    line = readline(stdin)
    isempty(strip(line)) && continue
    msg = try
        JSON.parse(line)
    catch e
        println(stderr, "unparseable line from the client: ", line)
        continue
    end
    push!(tasks, @async handle(msg))
end
# stdin is at EOF, which is the client asking us to exit. Finish what is in
# flight first, the way a real server would.
for t in tasks
    try
        wait(t)
    catch
    end
end
