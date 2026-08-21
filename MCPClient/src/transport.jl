"""
    AbstractTransport

The whole surface a transport must provide. [`Client`](@ref) builds and
interprets JSON-RPC messages; a transport only moves them, so a new transport is
a new type here rather than a change to the protocol layer.

Required methods:

  * `send_request!(t, message, id; timeout) -> AbstractDict` sends a request and
    returns the JSON-RPC response whose id matches `id`. Any other message seen
    while waiting must be handed to [`dispatch!`](@ref) rather than dropped.
  * `send_notification!(t, message) -> Nothing` sends a message that has no
    reply, and must not wait for one.
  * `Base.close(t)` releases the connection or child process, and must be safe
    to call twice.

Optional methods with defaults: [`session_id`](@ref), [`set_handler!`](@ref),
[`is_open`](@ref), [`protocol_version!`](@ref), [`start_listening!`](@ref).
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
    t.handler = f
    return nothing
end

"""
    is_open(t) -> Bool

Whether the transport can still be used. A transport is expected to become
closed exactly once.
"""
is_open(t::AbstractTransport) = !t.closed

"""
    dispatch!(t, message)

Hand an unsolicited message to the installed handler. Errors raised by the
handler are logged rather than propagated: a misbehaving handler must not turn
someone else's in-flight `tools/call` into a failure.
"""
function dispatch!(t::AbstractTransport, message::AbstractDict)
    handler = t.handler
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
# nor `readline` on a pipe accepts a deadline. The pattern is a one-slot channel
# that a `Timer` closes with a sentinel exception, so the caller returns on the
# deadline whether or not the reply ever arrives. Anything that can still produce
# the reply runs in a task (streamable HTTP) or on a shared reader (stdio) and
# publishes to the channel with [`deliver!`](@ref); the caller simply
# [`await_deadline`](@ref)s it.

struct DeadlineExpired <: Exception end

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
    await_deadline(d, timeout, method; cleanup=() -> nothing) -> Any

Wait for whatever is delivered to `d`, for at most `timeout` seconds, and
return it. A delivered `Exception` is rethrown, so a worker reports failure by
delivering it. After `timeout` seconds the wait gives up and throws
[`MCPTimeoutError`](@ref), first running `cleanup`, which should be cheap and
non-blocking (for example, cancelling the in-flight request).

`timeout <= 0` means wait indefinitely, which is occasionally what a caller
wants for a long-running tool.
"""
function await_deadline(
        d::Deadline, timeout::Real, method::AbstractString;
        cleanup::Function = () -> nothing
    )
    value = if timeout <= 0
        take!(d.channel)
    else
        timer = Timer(timeout) do _
            try
                close(d.channel, DeadlineExpired())
            catch
            end
        end
        try
            take!(d.channel)
        catch e
            if e isa DeadlineExpired
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

# ---------------------------------------------------------------------------
# Pending requests.
#
# The table of requests currently waiting for a reply, so that `close` can
# fail them instead of leaving their callers to their deadlines (which, with
# `timeout <= 0`, is forever). The transports key it differently -- streamable
# HTTP pairs one worker task with one request and uses a private token, stdio
# has one shared reader for every request and uses the JSON-RPC id -- but the
# table and its operations are the same. Every operation takes the transport's
# own lock, so a request registered just after a close is settled by that
# transport's existing single-lock protocol.

mutable struct Pending
    waiters::Dict{Any, Deadline}
    next::Int  # token source; stdio keys by id and never touches it
end

Pending() = Pending(Dict{Any, Deadline}(), 0)

unregister_pending!(p::Pending, lock, key) = @lock lock delete!(p.waiters, key)

"""
    take_pending!(p, lock, id) -> Union{Nothing,Deadline}

Remove and return the waiter registered under response id `id`. The direct
lookup already covers the numeric case; a server that changed the id's type
outright (echoing `1` as `"1"`) is rare enough to be worth a walk over the
handful of in-flight requests with [`ids_equal`](@ref).
"""
function take_pending!(p::Pending, lock, id)
    id === nothing && return nothing
    @lock lock begin
        d = pop!(p.waiters, id, nothing)
        d === nothing || return d
        for (key, waiter) in p.waiters
            if ids_equal(key, id)
                delete!(p.waiters, key)
                return waiter
            end
        end
        return nothing
    end
end

"""
    fail_pending!(p, lock, err)

Fail every waiter still in `p` with `err`. The entries are collected under
`lock` and the errors delivered outside it, in case a delivery re-enters the
transport.
"""
function fail_pending!(p::Pending, lock, err::Exception)
    waiters = @lock lock begin
        ws = collect(values(p.waiters))
        empty!(p.waiters)
        ws
    end
    for d in waiters
        deliver!(d, err)
    end
    return nothing
end

"""
    protocol_version!(t, version)

Tell a transport which protocol version was negotiated. Only transports that put
it on the wire (streamable HTTP sends an `MCP-Protocol-Version` header) do
anything with it.
"""
protocol_version!(::AbstractTransport, ::AbstractString) = nothing

"""
    start_listening!(t)

Ask a transport to start receiving server-initiated traffic that does not arrive
as part of a reply. [`initialize!`](@ref) calls this once the handshake is
complete, and only when a handler was installed, since a transport that has to
hold a connection open should not do so for traffic nobody consumes.

A transport whose messages already all arrive on one stream needs nothing here,
which is why the default does nothing: stdio has a single reader from the moment
the child starts. Streamable HTTP is the case this exists for, because a
notification the server sends between requests has no reply for it to ride along
with, and reaching it means opening the specification's standalone `GET` stream.

Must be safe to call more than once, and must not block.
"""
start_listening!(::AbstractTransport) = nothing

# Neither `wait(::Process)` nor `wait(::Task)` takes a deadline, and neither does
# "wait a while unless the transport closes first". Polling is coarse, but it is
# only used on shutdown and reconnect paths, where 20ms of granularity costs
# nothing.
function _poll(done::Function, seconds::Real)
    done() && return true
    deadline = time() + max(Float64(seconds), 0.0)
    while time() < deadline
        sleep(0.02)
        done() && return true
    end
    return done()
end
