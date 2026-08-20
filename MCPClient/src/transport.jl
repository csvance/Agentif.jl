"""
    AbstractTransport

The whole surface a transport must provide. [`Client`](@ref) builds and
interprets JSON-RPC messages; a transport only moves them, so adding stdio means
adding a type here rather than touching the protocol layer. See `STDIO.md`.

Required methods:

  * `send_request!(t, message, id; timeout) -> AbstractDict` sends a request and
    returns the JSON-RPC response whose id matches `id`. Any other message seen
    while waiting must be handed to [`dispatch!`](@ref) rather than dropped.
  * `send_notification!(t, message) -> Nothing` sends a message that has no
    reply, and must not wait for one.
  * `Base.close(t)` releases the connection or child process, and must be safe
    to call twice.

Optional methods with defaults: [`session_id`](@ref), [`set_handler!`](@ref),
[`is_open`](@ref).
"""
abstract type AbstractTransport end

function send_request! end
function send_notification! end

"""
    session_id(t) -> Union{Nothing,String}

Transport-level session identity, if the transport has one. Streamable HTTP
carries the server's `Mcp-Session-Id`; a stdio transport has no such concept and
returns `nothing`.
"""
session_id(::AbstractTransport) = nothing

"""
    set_handler!(t, f)

Install the callback invoked for every message the transport receives that is
not the response it was waiting for: server-initiated requests and
notifications. `f` takes the message `Dict{String,Any}`.
"""
function set_handler!(t::AbstractTransport, f)
    hasfield(typeof(t), :handler) ||
        throw(ArgumentError("$(typeof(t)) does not support incoming messages"))
    setfield!(t, :handler, f)
    return nothing
end

"""
    is_open(t) -> Bool

Whether the transport can still be used. A transport is expected to become
closed exactly once.
"""
is_open(t::AbstractTransport) = !getfield(t, :closed)

"""
    dispatch!(t, message)

Hand an unsolicited message to the installed handler. Errors raised by the
handler are logged rather than propagated: a misbehaving handler must not turn
someone else's in-flight `tools/call` into a failure.
"""
function dispatch!(t::AbstractTransport, message::AbstractDict)
    handler = getfield(t, :handler)
    handler === nothing && return nothing
    try
        handler(message)
    catch e
        @error "MCP incoming-message handler failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Deadline plumbing shared by transports.
#
# A transport must never block a caller forever, and neither `read` on a socket
# nor `readline` on a pipe accepts a deadline. The pattern below runs the
# blocking work in a task and waits on a one-slot channel that a `Timer` closes
# with a sentinel exception, so the caller returns on the deadline whether or not
# the worker ever notices. The worker is then abandoned, which is why every
# transport also supplies a cleanup that tears its connection down.

struct _Timeout <: Exception end

struct Deadline
    channel::Channel{Any}
    delivered::Base.RefValue{Bool}
end

Deadline() = Deadline(Channel{Any}(1), Ref(false))

"""
    deliver!(d, value)

Publish the first value produced for this deadline; later calls are ignored, so
a worker that finds its answer mid-stream can keep tidying up afterwards without
overwriting the result or blocking on a channel nobody reads.
"""
function deliver!(d::Deadline, value)
    d.delivered[] && return nothing
    d.delivered[] = true
    try
        put!(d.channel, value)
    catch
        # The waiter already gave up and closed the channel.
    end
    return nothing
end

"""
    run_with_deadline(work, timeout, method; cleanup=() -> nothing) -> Any

Run `work(deadline)` in a task and return the first value it delivers, or throw
[`MCPTimeoutError`](@ref) after `timeout` seconds. A delivered `Exception` is
rethrown, so a worker reports failure by delivering it. `cleanup` runs only on
the timeout path and should be cheap and non-blocking.

`timeout <= 0` means wait indefinitely, which is occasionally what a caller
wants for a long-running tool.
"""
function run_with_deadline(work::Function, timeout::Real, method::AbstractString;
                           cleanup::Function=() -> nothing)
    d = Deadline()
    @async begin
        try
            work(d)
            # A worker that finishes without delivering saw no reply at all.
            deliver!(d, nothing)
        catch e
            deliver!(d, e isa Exception ? e : ErrorException(string(e)))
        end
    end
    return await_deadline(d, timeout, method; cleanup=cleanup)
end

"""
    await_deadline(d, timeout, method; cleanup=() -> nothing) -> Any

Wait for whatever is delivered to `d`, for at most `timeout` seconds. A transport
whose replies arrive on a shared reader task (stdio, for instance) creates the
`Deadline`, registers it under the request id and waits here, rather than pairing
one worker task with one request the way [`run_with_deadline`](@ref) does.
"""
function await_deadline(d::Deadline, timeout::Real, method::AbstractString;
                        cleanup::Function=() -> nothing)
    value = if timeout <= 0
        take!(d.channel)
    else
        timer = Timer(timeout) do _
            try
                close(d.channel, _Timeout())
            catch
            end
        end
        try
            take!(d.channel)
        catch e
            if e isa _Timeout
                try
                    cleanup()
                catch
                end
                throw(MCPTimeoutError(String(method), Float64(timeout)))
            end
            rethrow()
        finally
            close(timer)
        end
    end
    value isa Exception && throw(value)
    return value
end

"""
    protocol_version!(t, version)

Tell a transport which protocol version was negotiated. Only transports that put
it on the wire (streamable HTTP sends an `MCP-Protocol-Version` header) do
anything with it.
"""
protocol_version!(::AbstractTransport, ::AbstractString) = nothing
