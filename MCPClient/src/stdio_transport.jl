# Stdio transport: the client spawns the server as a child process and speaks
# newline-delimited JSON-RPC over its stdin and stdout, exactly one message per
# line. There is no framing header, no session id and no URL, and the child's
# stderr is its log stream rather than protocol.
#
# The structural difference from streamable HTTP is that a reply does not arrive
# on the call that sent the request. HTTP hands back a body per POST, so
# correlating a response with its request is local to one function; stdio has one
# shared byte stream, so a single reader task owns it and a table of pending
# deadlines keyed by JSON-RPC id is what gets a response back to its caller.

"""
    StdioTransport(command; env=nothing, dir=nothing, inherit_env=true,
                   timeout=30.0, close_grace=2.0, stderr_lines=50)

Transport that runs an MCP server as a child process and speaks JSON-RPC over its
stdin and stdout.

`command` is a `Cmd`, for example `` `npx -y @modelcontextprotocol/server-everything` ``.
`env` adds environment variables, which is how MCP servers are almost always
configured; by default they are added to the environment this process already
has, because a server invoked through `npx` or `uvx` needs `PATH` and `HOME` to
survive. Pass `inherit_env=false` to hand the child only what `env` names.
`dir` sets the child's working directory. `timeout` is the per-request deadline
in seconds; `<= 0` waits forever. `close_grace` is how long [`close`](@ref)
gives the child to exit at each escalation step. `stderr_lines` bounds the tail
of the child's stderr kept for diagnostics, see [`stderr_tail`](@ref).

There is no session id and no protocol-version header, so [`session_id`](@ref)
stays `nothing` and `protocol_version!` is a no-op.

Construct a [`Client`](@ref) instead of using this type directly unless you need
to speak raw JSON-RPC. Note that the installed handler runs on the reader task,
so a handler must not block and must never itself call [`send_request!`](@ref):
the response it waited for could only be read by the task it is blocking.
"""
mutable struct StdioTransport <: AbstractTransport
    command::Base.Cmd
    process::Base.Process
    stdin::IO                            # the child's stdin; we write
    stdout::IO                           # the child's stdout; we read
    stderr::IO                           # the child's stderr; log stream only
    timeout::Float64
    close_grace::Float64
    pending::Dict{Any,Deadline}          # JSON-RPC id -> the caller waiting for it
    handler::Any
    reader::Union{Nothing,Task}
    stderr_reader::Union{Nothing,Task}
    stderr_lines::Int
    stderr_log::Vector{String}
    failure::Union{Nothing,MCPTransportError}
    closed::Bool
    write_lock::ReentrantLock
    lock::ReentrantLock
end

function StdioTransport(command::Base.Cmd;
                        env=nothing,
                        dir=nothing,
                        inherit_env::Bool=true,
                        timeout::Real=DEFAULT_TIMEOUT,
                        close_grace::Real=2.0,
                        stderr_lines::Integer=50)
    cmd = _child_command(command, env, dir, inherit_env)
    # A fresh PipeEndpoint, not a `Pipe`: `pipeline` closes the child end at spawn,
    # which is what makes `eof` on stdout true once the child exits. Holding a
    # write end ourselves would make a dead child look like an idle one.
    child_stderr = Base.PipeEndpoint()
    process = try
        open(pipeline(cmd; stderr=child_stderr), "r+")
    catch e
        throw(MCPTransportError("could not start the MCP server `$(cmd)`", e))
    end
    t = StdioTransport(cmd, process, process.in, process.out, child_stderr,
                       Float64(timeout), Float64(close_grace), Dict{Any,Deadline}(),
                       nothing, nothing, nothing, Int(stderr_lines), String[],
                       nothing, false, ReentrantLock(), ReentrantLock())
    # Both readers start before this returns: a server that logs during startup
    # blocks in `write` once the stderr pipe buffer fills, and that deadlock looks
    # exactly like a server that never answers the handshake.
    t.stderr_reader = @async _drain_stderr!(t)
    t.reader = @async _read_loop!(t)
    return t
end

function _child_command(command::Base.Cmd, env, dir, inherit_env::Bool)
    cmd = command
    if env !== nothing || !inherit_env
        merged = Dict{String,String}()
        inherit_env && for (k, v) in ENV
            merged[String(k)] = String(v)
        end
        env === nothing || for (k, v) in _env_pairs(env)
            merged[String(k)] = String(v)
        end
        cmd = Base.Cmd(cmd; env=merged)
    end
    dir === nothing || (cmd = Base.Cmd(cmd; dir=String(dir)))
    return cmd
end

_env_pairs(env::NamedTuple) = pairs(env)
_env_pairs(env) = env  # a dict, or a vector of `"K" => "V"` pairs

Base.show(io::IO, t::StdioTransport) = print(io, "StdioTransport(", t.command,
                                             _state_suffix(t), ")")

function _state_suffix(t::StdioTransport)
    @lock t.lock begin
        t.closed && return ", closed"
        t.failure === nothing || return ", failed"
    end
    return ""
end

"""
    is_open(t::StdioTransport) -> Bool

Whether the transport can still carry a message. Unlike HTTP, a stdio transport
can be killed from the far side: the child exiting makes it unusable without
anyone having called [`close`](@ref).
"""
is_open(t::StdioTransport) = @lock t.lock (!t.closed && t.failure === nothing)

"""
    stderr_tail(t) -> Vector{String}

The last few lines the child wrote to stderr, most recent last. The child's log
stream is the only explanation an MCP server gives for exiting during startup, so
a bounded tail of it is kept and quoted in the error every pending request gets
when the process dies. The bound exists because a chatty server would otherwise
grow this without limit for the whole life of the session.
"""
stderr_tail(t::StdioTransport) = @lock t.lock copy(t.stderr_log)

# --- reading --------------------------------------------------------------

function _read_loop!(t::StdioTransport)
    try
        while !eof(t.stdout)
            line = readline(t.stdout)
            # `readline` reassembles a message split across several pipe reads.
            isempty(strip(line)) && continue
            msgs = try
                parse_payload(line)
            catch e
                # A banner or stray log line on stdout is the commonest cause of a
                # broken stdio connection, and taking the session down for it
                # turns a cosmetic bug in someone else's server into an outage.
                @warn "ignoring a line on the MCP server's stdout that is not JSON-RPC" line = _snippet(line)
                continue
            end
            for msg in msgs
                _route_incoming!(t, msg)
            end
        end
    catch e
        # Reading also ends this way when `close` tears the pipe down underneath
        # us, which is not a failure worth reporting to anyone.
        @debug "the MCP stdio reader stopped" exception = (e, catch_backtrace())
    finally
        # stdout is at EOF, so no response can arrive again and every waiter has
        # to be told now: leaving them to their deadlines makes a process that
        # died instantly look like one that is merely slow. On the ordinary
        # shutdown path the answer is already known, so skip the exit code and the
        # log tail rather than make `close` wait for them.
        err = @lock(t.lock, t.closed) ?
              MCPTransportError("the stdio transport for `$(t.command)` was closed") :
              _death_error(t)
        _record_failure!(t, err)
        _fail_pending!(t, err)
    end
    return nothing
end

function _route_incoming!(t::StdioTransport, msg::AbstractDict)
    if is_response(msg)
        d = _take_pending!(t, get(msg, "id", nothing))
        if d === nothing
            # Either the caller already timed out and stopped waiting, or the
            # server answered a request nobody made. Neither is fatal.
            @debug "an MCP response arrived with no request waiting for it" id = get(msg, "id", nothing)
        else
            deliver!(d, msg)
        end
        return nothing
    end
    # Everything else is the server's own traffic: notifications and requests. The
    # contract is that nothing seen on the stream is dropped.
    dispatch!(t, msg)
    return nothing
end

# Ids are opaque, and a server may echo `1` as `1.0` or as `"1"`. The dictionary
# lookup already covers the numeric case, so the scan is only reached for a
# server that changed the type outright, which is rare enough to be worth a walk
# over the handful of requests that are in flight.
function _take_pending!(t::StdioTransport, id)
    id === nothing && return nothing
    @lock t.lock begin
        d = pop!(t.pending, id, nothing)
        d === nothing || return d
        for (key, waiter) in t.pending
            if ids_equal(key, id)
                delete!(t.pending, key)
                return waiter
            end
        end
        return nothing
    end
end

function _drain_stderr!(t::StdioTransport)
    try
        while !eof(t.stderr)
            line = readline(t.stderr)
            isempty(line) && continue
            @debug "MCP server stderr" line
            @lock t.lock begin
                push!(t.stderr_log, line)
                # Drop from the front rather than clearing: the last lines before
                # an exit are the ones that say why it exited.
                length(t.stderr_log) > t.stderr_lines && popfirst!(t.stderr_log)
            end
        end
    catch e
        @debug "the MCP stderr drain stopped" exception = (e, catch_backtrace())
    end
    return nothing
end

# --- failure bookkeeping --------------------------------------------------

function _death_error(t::StdioTransport)
    # The child may not be reaped yet at the moment stdout hits EOF, so give it a
    # moment; but do not wait on it, because a server is allowed to close stdout
    # and keep running, and blocking here would hold back the errors that every
    # pending caller is waiting for.
    exited = _wait_exit(t.process, 0.25)
    # A server that logs why it is dying does so just before it dies, so the tail
    # is only useful if the drain has caught up. Its stderr is at EOF once the
    # child is gone, so this waits for the task to end rather than for a duration.
    exited && t.stderr_reader !== nothing && _wait_task(t.stderr_reader, 0.25)
    detail = if exited
        code = t.process.exitcode
        signal = t.process.termsignal
        signal > 0 ? "was killed by signal $signal" : "exited with code $code"
    else
        "closed its stdout while still running"
    end
    tail = stderr_tail(t)
    message = "the MCP server `$(t.command)` $detail"
    isempty(tail) || (message *= "; last stderr: " * _snippet(join(tail, " | "), 600))
    return MCPTransportError(message, nothing)
end

function _record_failure!(t::StdioTransport, err::MCPTransportError)
    @lock t.lock (t.failure === nothing && (t.failure = err))
    return nothing
end

function _fail_pending!(t::StdioTransport, err::Exception)
    waiters = @lock t.lock begin
        ws = collect(values(t.pending))
        empty!(t.pending)
        ws
    end
    for d in waiters
        deliver!(d, err)
    end
    return nothing
end

# --- sending --------------------------------------------------------------

function send_request!(t::StdioTransport, message::AbstractDict, id;
                       timeout::Real=t.timeout)
    method = _method_of(message)
    d = Deadline()
    # Registering the waiter and checking that the transport is still alive happen
    # under one lock, and the reader empties `pending` under the same one. Without
    # that, a request registered just after the child died would be delivered
    # nothing and would sit out its whole timeout.
    err = @lock t.lock begin
        if t.closed || t.failure !== nothing
            _unusable(t, method)
        elseif haskey(t.pending, id)
            # Overwriting the entry would orphan whoever registered it, leaving
            # that caller to hang out its deadline for a response handed to
            # someone else. `Client` never reuses an id; raw JSON-RPC can.
            MCPProtocolError("a request with id $(repr(id)) is already in flight; " *
                             "JSON-RPC ids must be unique while a request is outstanding")
        else
            t.pending[id] = d
            nothing
        end
    end
    err === nothing || throw(err)
    try
        _write_message!(t, message, method)
        return await_deadline(d, timeout, method)
    finally
        # Covers all three exits: the response arrived, the deadline passed, or
        # the write failed. A waiter left behind would keep a dead id in the table
        # for the life of the session.
        @lock t.lock delete!(t.pending, id)
    end
end

function send_notification!(t::StdioTransport, message::AbstractDict;
                            timeout::Real=t.timeout)
    # `timeout` is accepted for signature parity with the HTTP transport, which
    # has to wait for the POST to be accepted. Here there is nothing to wait for:
    # a notification is one line written to a pipe and no reply will ever come.
    method = _method_of(message)
    err = @lock t.lock (t.closed || t.failure !== nothing ? _unusable(t, method) : nothing)
    err === nothing || throw(err)
    _write_message!(t, message, method)
    return nothing
end

# A response the client sends back to the server has no "method" member, so this
# is only ever used to name the failure in an error message.
_method_of(message::AbstractDict) = String(get(message, "method", "a response"))

# Call under `t.lock`: reports why the transport cannot carry `method`.
_unusable(t::StdioTransport, method::AbstractString) =
    t.failure !== nothing && !t.closed ? t.failure :
    MCPTransportError("the stdio transport for `$(t.command)` is closed, so \"$method\" cannot be sent")

function _write_message!(t::StdioTransport, message::AbstractDict, method::AbstractString)
    json = JSON.json(message)
    # One message per line is the entire framing, so an embedded newline would
    # split one message into two invalid ones. `JSON.json` escapes newlines, so
    # this asserts rather than sanitises.
    occursin('\n', json) &&
        throw(MCPProtocolError("refusing to send \"$method\": its JSON contains a newline, " *
                               "which stdio framing cannot carry"))
    try
        # The lock covers the payload and its terminator together: two tasks each
        # writing half a message produce two invalid lines the server cannot
        # recover the boundary from. There is deliberately no deadline here, since
        # abandoning a half-written line corrupts every message after it; MCP
        # messages sit far below a pipe buffer, so only a wedged child can block.
        @lock t.write_lock begin
            write(t.stdin, json)
            write(t.stdin, '\n')
            flush(t.stdin)
        end
    catch e
        e isa MCPException && rethrow()
        throw(MCPTransportError(
            "could not write \"$method\" to the stdin of `$(t.command)`", e))
    end
    return nothing
end

# --- shutdown -------------------------------------------------------------

"""
    close(t::StdioTransport)

Shut the child process down and release its pipes. Safe to call twice, and safe
when the process is already dead.

The escalation is the one the MCP specification asks for, because a server killed
mid-write leaves a half-written line and, worse, may leave its own side effects
half-done: close its stdin, which is the documented signal to exit; wait; then
`SIGTERM`; wait; then `SIGKILL`.
"""
function Base.close(t::StdioTransport)
    already = @lock t.lock begin
        was = t.closed
        t.closed = true
        was
    end
    already && return nothing

    try
        close(t.stdin)
    catch e
        @debug "could not close the MCP server's stdin" exception = e
    end
    if !_wait_exit(t.process, t.close_grace)
        _signal(t, Base.SIGTERM)
        if !_wait_exit(t.process, t.close_grace)
            _signal(t, Base.SIGKILL)
            _wait_exit(t.process, t.close_grace)
        end
    end

    _fail_pending!(t, MCPTransportError(
        "the stdio transport for `$(t.command)` was closed while the request was in flight"))

    # Closing the read ends unblocks the readers even when a grandchild inherited
    # the pipes, the one case where the child exiting is not enough.
    for pipe in (t.stdout, t.stderr)
        try
            close(pipe)
        catch
        end
    end
    for task in (t.reader, t.stderr_reader)
        task === nothing && continue
        _wait_task(task, t.close_grace)
    end
    return nothing
end

function _signal(t::StdioTransport, signum::Integer)
    try
        kill(t.process, signum)
    catch e
        # The process may have exited between the check and here, which is not an
        # error: it is the outcome we wanted.
        @debug "could not signal the MCP server" signum exception = e
    end
    return nothing
end

# Neither `wait(::Process)` nor `wait(::Task)` takes a deadline, and `close` must
# not be able to hang. Polling is coarse but it is only ever used on the shutdown
# path, where a 20ms granularity costs nothing.
function _wait_exit(process::Base.Process, seconds::Real)
    return _poll(() -> process_exited(process), seconds)
end

_wait_task(task::Task, seconds::Real) = _poll(() -> istaskdone(task), seconds)

function _poll(done::Function, seconds::Real)
    done() && return true
    deadline = time() + max(Float64(seconds), 0.0)
    while time() < deadline
        sleep(0.02)
        done() && return true
    end
    return done()
end
