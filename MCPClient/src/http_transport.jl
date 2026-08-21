# Streamable HTTP transport (MCP revision 2025-03-26 onwards).
#
# One endpoint URL takes every message by POST. The interesting wrinkle is that a
# single POST may be answered in either of two ways: a plain `application/json`
# body holding one JSON-RPC response, or a `text/event-stream` body on which the
# server may emit progress notifications and its own requests before the response
# we are waiting for. Both are handled here so the layer above sees only a
# response dictionary.
#
# A reply is not the only thing a server sends, though. Anything it wants to say
# between requests -- a log message, `tools/list_changed`, a request of its own --
# has no POST to ride along with, and reaching it means holding open the
# specification's standalone `GET` stream. That listener is the other half of
# this file, and unlike the POST path it is long-lived: it reconnects, it resumes
# with `Last-Event-ID`, and it has to be torn down by `close`.

# State of the standalone `GET` stream. Kept in its own struct because none of it
# means anything to the POST path, and a transport whose fields are half "how we
# send" and half "how we listen" reads as one thing doing two jobs.
mutable struct Listener
    task::Union{Nothing, Task}
    # The in-flight GET, so `close` can abandon a read that would otherwise sit
    # on an idle stream until the server got round to ending it.
    ctx::Any
    stream::Any
    # Sent back as `Last-Event-ID` on reconnect, so a server that supports
    # resumability replays what was emitted while we were not connected.
    last_event_id::Union{Nothing, String}
    # The server told us it does not do this, so stop asking.
    refused::Bool
end

Listener() = Listener(nothing, nothing, nothing, nothing, false)

"""
    StreamableHTTPTransport(url; headers=[], timeout=30.0, terminate_on_close=true)

Transport that POSTs JSON-RPC to a single MCP endpoint.

`headers` are sent on every request, which is where an `Authorization` header
belongs. `timeout` is the per-request deadline in seconds; `<= 0` waits forever.
`terminate_on_close` sends the spec's `DELETE` on [`close`](@ref) so the server
can release the session, which servers are allowed to reject.

The session id the server returns from `initialize` is captured automatically and
sent on every later request. Construct a [`Client`](@ref) instead of using this
type directly unless you need to speak raw JSON-RPC.

Server-initiated traffic that arrives between requests needs the standalone `GET`
stream, which [`start_listening!`](@ref) opens; [`Client`](@ref) does that for
you when you pass a handler. A server is free to refuse the stream with HTTP 405,
in which case only notifications interleaved into a reply are seen.
"""
mutable struct StreamableHTTPTransport <: AbstractTransport
    url::String
    headers::Vector{Pair{String, String}}
    timeout::Float64
    session_id::Union{Nothing, String}
    protocol_version::Union{Nothing, String}
    handler::Any
    closed::Bool
    # Set when the far side made the transport permanently unusable, which for
    # HTTP means the server declared the session gone. Without it a caller
    # polling `is_open` is told a transport is fine while every call on it fails,
    # the same lie the stdio transport avoids with its own `failure` field.
    failure::Union{Nothing, MCPTransportError}
    terminate_on_close::Bool
    http_client::HTTP.Client
    # Every exchange currently waiting for a reply, so `close` can wake it. A
    # closed socket does not by itself unblock the caller: its `Deadline` lives
    # on the worker task, so without this table the caller waits out its full
    # timeout after `close` returns, and with `timeout <= 0` waits forever.
    pending::Pending
    listener::Listener
    lock::ReentrantLock
end

function StreamableHTTPTransport(
        url::AbstractString;
        headers = Pair{String, String}[],
        timeout::Real = DEFAULT_TIMEOUT,
        terminate_on_close::Bool = true
    )
    hs = Pair{String, String}[String(k) => String(v) for (k, v) in headers]
    # One client per transport: its connection pool keeps a session's calls off a
    # fresh TCP (and TLS) handshake each time, which otherwise dominates the cost
    # of a small tools/call.
    return StreamableHTTPTransport(
        String(url), hs, Float64(timeout), nothing, nothing,
        nothing, false, nothing, terminate_on_close, HTTP.Client(),
        Pending(), Listener(), ReentrantLock()
    )
end

session_id(t::StreamableHTTPTransport) = @lock t.lock t.session_id

"""
    is_open(t::StreamableHTTPTransport) -> Bool

Whether the transport can still carry a message. As well as having been closed
here, an HTTP transport can be finished off from the far side: a server that
answers 404 for a session id it issued has ended that session, and no later
request on this transport can succeed.
"""
is_open(t::StreamableHTTPTransport) = @lock t.lock (!t.closed && t.failure === nothing)

# Records the first permanent failure only: later ones are consequences of it,
# and the first is the one that explains what happened.
function _record_failure!(t::StreamableHTTPTransport, err::MCPTransportError)
    @lock t.lock (t.failure === nothing && (t.failure = err))
    return nothing
end

"""
    protocol_version!(t, version)

Record the negotiated protocol version so it can be sent as the
`MCP-Protocol-Version` header, which servers use to keep older clients working.
"""
protocol_version!(t::StreamableHTTPTransport, version::AbstractString) =
    @lock t.lock (t.protocol_version = String(version))

Base.show(io::IO, t::StreamableHTTPTransport) =
    print(io, "StreamableHTTPTransport(", t.url, _state_suffix(t), ")")

function _state_suffix(t::StreamableHTTPTransport)
    @lock t.lock begin
        t.closed && return ", closed"
        t.failure === nothing || return ", failed"
    end
    return ""
end

function _request_headers(t::StreamableHTTPTransport)
    hs = Pair{String, String}[
        "Content-Type" => "application/json",
        # Both are advertised because the server chooses which one to answer with.
        "Accept" => "application/json, text/event-stream",
    ]
    @lock t.lock begin
        t.session_id === nothing || push!(hs, "Mcp-Session-Id" => t.session_id)
        t.protocol_version === nothing || push!(hs, "MCP-Protocol-Version" => t.protocol_version)
    end
    append!(hs, t.headers)
    return hs
end

function _capture_session!(t::StreamableHTTPTransport, response)
    sid = HTTP.header(response, "Mcp-Session-Id", "")
    isempty(sid) && return nothing
    @lock t.lock (t.session_id = String(sid))
    return nothing
end

function send_request!(
        t::StreamableHTTPTransport, message::AbstractDict, id;
        timeout::Real = t.timeout
    )
    method = String(get(message, "method", "?"))
    is_open(t) || throw(_unusable(t, method))
    reply = _exchange(t, message, id, timeout, method)
    reply === nothing && throw(
        MCPProtocolError(
            "the server accepted \"$method\" without answering it; a request must get a response"
        )
    )
    return reply
end

function send_notification!(
        t::StreamableHTTPTransport, message::AbstractDict;
        timeout::Real = t.timeout
    )
    method = String(get(message, "method", "?"))
    is_open(t) || throw(_unusable(t, method))
    _exchange(t, message, nothing, timeout, method)
    return nothing
end

# Why the transport cannot carry `method`. A recorded failure is the more useful
# answer of the two, since "closed" is something the caller did and a failure is
# something that happened to them.
_unusable(t::StreamableHTTPTransport, method::AbstractString) =
    @lock t.lock (
    t.failure !== nothing && !t.closed ? t.failure :
        MCPTransportError("the transport for $(t.url) is closed, so \"$method\" cannot be sent")
)

# Perform one POST. Returns the response matching `want_id`, or nothing when
# there was none (the normal outcome for a notification, which servers answer
# with 202 Accepted and an empty body).
function _exchange(
        t::StreamableHTTPTransport, message::AbstractDict, want_id,
        timeout::Real, method::AbstractString
    )
    payload = JSON.json(message)
    stream_ref = Ref{Any}(nothing)
    # A RequestContext is how HTTP.jl is told to abandon a request that is still
    # in flight, which releases the pooled connection instead of leaking it.
    ctx = HTTP.RequestContext()
    cleanup = function ()
        try
            HTTP.cancel!(ctx; message = "MCP request timed out")
        catch
        end
        s = stream_ref[]
        # Closing can itself block on a wedged connection, so never do it on the
        # caller's task.
        s === nothing || @async (
            try
                close(s)
            catch end
        )
        return nothing
    end
    d = Deadline()
    # The worker owns the blocking read and registers itself just before it, so
    # a request registered just after a close cannot be stranded. A worker that
    # finishes without delivering saw no reply at all; the caller reports that
    # as a protocol error.
    @async begin
        token = nothing
        try
            token = _register_pending!(t, d, method)
            _post(t, payload, want_id, method, stream_ref, ctx, d)
            deliver!(d, nothing)
        catch e
            deliver!(d, e isa Exception ? e : ErrorException(string(e)))
        finally
            token === nothing || unregister_pending!(t.pending, t.lock, token)
        end
    end
    return await_deadline(d, timeout, method; cleanup = cleanup)
end

function _register_pending!(t::StreamableHTTPTransport, d::Deadline, method::AbstractString)
    # Registering the waiter and re-checking `closed` happen under one lock, and
    # `close` empties the table under the same one, so a request registered
    # just after a close cannot be stranded.
    @lock t.lock begin
        t.closed && throw(MCPTransportError("transport for $(t.url) was closed before \"$method\" was sent"))
        t.pending.next += 1
        t.pending.waiters[t.pending.next] = d
        return t.pending.next
    end
end

function _post(
        t::StreamableHTTPTransport, payload::String, want_id, method::AbstractString,
        stream_ref::Ref{Any}, ctx, d::Deadline
    )
    # retry=false: a JSON-RPC request is not idempotent, and a retried tools/call
    # could run a side effect twice. status_exception=false: a non-2xx body often
    # explains what went wrong and is worth putting in the error message.
    try
        HTTP.open(
            "POST", t.url, _request_headers(t); retry = false, status_exception = false,
            context = ctx, client = t.http_client
        ) do stream
            stream_ref[] = stream
            write(stream, payload)
            HTTP.closewrite(stream)
            response = HTTP.startread(stream)
            _capture_session!(t, response)
            status = response.status
            if status == 202 || status == 204
                # Accepted with no body: the correct answer to a notification or
                # to a response we sent.
                return nothing
            elseif status >= 300
                _throw_status(t, status, stream)
            end
            content_type = lowercase(HTTP.header(response, "Content-Type", ""))
            if occursin("text/event-stream", content_type)
                _read_sse!(t, stream, want_id, d)
            else
                body = read(stream, String)
                isempty(strip(body)) && return nothing
                for msg in parse_payload(body)
                    _route!(t, msg, want_id, d)
                end
            end
            return nothing
        end
    catch e
        e isa MCPException && rethrow()
        throw(MCPTransportError("POST to $(t.url) for \"$method\" failed", e))
    end
    return nothing
end

function _throw_status(t::StreamableHTTPTransport, status::Integer, stream)
    body = try
        read(stream, String)
    catch
        ""
    end
    if status == 404 && session_id(t) !== nothing
        # The session is gone, so nothing sent on this transport can ever succeed
        # again. Recording it is what makes `is_open` say so, instead of leaving a
        # caller to discover it one failed call at a time.
        err = MCPTransportError(
            "MCP session $(session_id(t)) is no longer valid (HTTP 404); open a new client"
        )
        _record_failure!(t, err)
        throw(err)
    elseif status == 405
        throw(MCPTransportError("$(t.url) does not accept POST (HTTP 405)"))
    elseif status == 401 || status == 403
        throw(MCPTransportError("not authorized for $(t.url) (HTTP $status): $(_snippet(body))"))
    end
    throw(MCPTransportError("HTTP $status from $(t.url): $(_snippet(body))"))
end

# Send the response we are waiting for to the caller, and everything else to the
# handler. Nothing on the wire is silently dropped.
function _route!(t::StreamableHTTPTransport, msg::AbstractDict, want_id, d::Deadline)
    if want_id !== nothing && is_response(msg) && ids_equal(get(msg, "id", nothing), want_id)
        deliver!(d, msg)
        return true
    end
    dispatch!(t, msg)
    return false
end

function _read_sse!(
        t::StreamableHTTPTransport, stream, want_id, d::Deadline;
        record_id::Bool = false
    )
    parser = SSEParser()
    while !eof(stream)
        line = readline(stream)
        event = feed_line!(parser, line)
        event === nothing && continue
        # Record the id before the payload is even looked at: resuming correctly
        # after an event we could not parse still means not asking for it twice.
        if record_id && event.id !== nothing
            @lock t.lock (t.listener.last_event_id = event.id)
        end
        isempty(strip(event.data)) && continue
        # An MCP server puts one JSON-RPC message in each event's data field. A
        # stray non-JSON event (a keep-alive that is not a comment, say) is worth
        # a warning but must not sink the request.
        msgs = try
            parse_payload(event.data)
        catch e
            @warn "ignoring an SSE event whose data is not JSON-RPC" exception = e
            continue
        end
        for msg in msgs
            # Stop reading once our response arrives: the spec says the server
            # SHOULD close the stream then, and waiting for it to do so would
            # hold the caller for no benefit.
            _route!(t, msg, want_id, d) && return nothing
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# The standalone SSE stream.
#
# `GET` on the same endpoint, held open, carrying whatever the server has to say
# when there is no reply for it to travel with. Two things make this more than a
# read loop. It has to end: `close` must not wait for a server to get round to
# finishing a stream it has no reason to finish, so the read is abandoned rather
# than waited out. And it has to survive: a stream that dies on the first idle
# timeout is a promise of notifications that quietly stops being kept, which is
# worse than not offering one, so it reconnects and resumes.

# Backoff between reconnects, in seconds, indexed by consecutive failures. A
# clean end to the stream does not consume one of these, because a server is
# allowed to close the stream whenever it likes and reconnecting promptly is the
# right answer.
const _LISTEN_BACKOFF = (0.5, 1.0, 2.0, 5.0, 10.0)

# ...but only if the stream was actually up for a moment. A server that offers
# the stream and then ends it immediately, every time, would otherwise have this
# reconnecting in a tight loop for the life of the session: "it ended cleanly"
# and "it never worked" look identical from one attempt. Below this, a clean end
# counts as a failure and backs off like one.
const _LISTEN_MIN_UPTIME = 1.0

"""
    start_listening!(t::StreamableHTTPTransport)

Open the standalone `GET` stream, on a task of its own, and keep it open for as
long as the transport is usable. Safe to call more than once; the second call
does nothing. [`initialize!`](@ref) calls this, so there is normally no reason to.
"""
function start_listening!(t::StreamableHTTPTransport)
    @lock t.lock begin
        (t.closed || t.failure !== nothing || t.listener.refused) && return nothing
        t.listener.task === nothing || return nothing
        t.listener.task = @async _listen_loop!(t)
    end
    return nothing
end

function _listen_loop!(t::StreamableHTTPTransport)
    failures = 0
    while is_open(t)
        started = time()
        outcome = try
            _listen_once!(t)
        catch e
            # A connection that dropped mid-stream. Worth a debug line and a
            # retry, not an error: this is the ordinary weather of a long-lived
            # connection, and the caller has no action to take.
            @debug "the MCP standalone SSE stream dropped" exception = (e, catch_backtrace())
            :backoff
        end
        outcome === :stop && break
        is_open(t) || break
        if outcome === :reconnect && time() - started >= _LISTEN_MIN_UPTIME
            # The server ended a stream that had been up and working, which it
            # may do at will. Go straight back rather than treating it as a fault.
            failures = 0
        else
            failures += 1
            delay = _LISTEN_BACKOFF[min(failures, length(_LISTEN_BACKOFF))]
            # Wait out the backoff, but return the moment the transport closes:
            # `close` must not be held up by a stream that is only sleeping.
            _poll(() -> !is_open(t), delay) && break
        end
    end
    @lock t.lock (t.listener.task = nothing)
    return nothing
end

# One GET, read to its end. Returns what the loop should do next.
function _listen_once!(t::StreamableHTTPTransport)
    ctx = HTTP.RequestContext()
    @lock t.lock (t.listener.ctx = ctx)
    outcome = :backoff
    try
        HTTP.open(
            "GET", t.url, _listen_headers(t); retry = false, status_exception = false,
            context = ctx, client = t.http_client
        ) do stream
            @lock t.lock (t.listener.stream = stream)
            response = HTTP.startread(stream)
            _capture_session!(t, response)
            outcome = _listen_status(t, response)
            outcome === :read || return nothing
            # `want_id = nothing` is the whole point: nothing here is a reply we
            # asked for, so every message goes to the handler, and the read runs
            # to the end of the stream rather than stopping on a match.
            _read_sse!(t, stream, nothing, Deadline(); record_id = true)
            outcome = :reconnect
            return nothing
        end
    finally
        @lock t.lock begin
            t.listener.ctx = nothing
            t.listener.stream = nothing
        end
    end
    return outcome
end

# What a status on the standalone stream means for the listener.
function _listen_status(t::StreamableHTTPTransport, response)
    status = response.status
    if status == 405 || status == 501
        # The specification says in as many words that a server MAY answer this,
        # meaning it offers no standalone stream. Asking again would be rude and
        # pointless; only notifications interleaved into a reply will be seen.
        @debug "the MCP server offers no standalone SSE stream" url = t.url status
        @lock t.lock (t.listener.refused = true)
        return :stop
    elseif status == 404 && session_id(t) !== nothing
        _record_failure!(
            t, MCPTransportError(
                "MCP session $(session_id(t)) is no longer valid (HTTP 404); open a new client"
            )
        )
        return :stop
    elseif status == 401 || status == 403
        # Credentials are fixed when the transport is built, so a retry sends the
        # same rejected header again.
        @debug "not authorized to open the MCP standalone SSE stream" url = t.url status
        @lock t.lock (t.listener.refused = true)
        return :stop
    elseif status >= 300
        # Anything else may be transient, so let the loop back off and retry.
        @debug "unexpected status on the MCP standalone SSE stream" url = t.url status
        return :backoff
    end
    content_type = lowercase(HTTP.header(response, "Content-Type", ""))
    if !occursin("text/event-stream", content_type)
        # A 200 that is not a stream is a server doing something else entirely
        # with this URL. Reconnecting in a loop would just hammer it.
        @debug "the MCP standalone stream answered with an unexpected content type" content_type
        @lock t.lock (t.listener.refused = true)
        return :stop
    end
    return :read
end

function _listen_headers(t::StreamableHTTPTransport)
    # No Content-Type: a GET carries no body. Only the stream is acceptable here,
    # unlike a POST, which has to advertise both forms.
    hs = Pair{String, String}["Accept" => "text/event-stream"]
    @lock t.lock begin
        t.session_id === nothing || push!(hs, "Mcp-Session-Id" => t.session_id)
        t.protocol_version === nothing || push!(hs, "MCP-Protocol-Version" => t.protocol_version)
        t.listener.last_event_id === nothing ||
            push!(hs, "Last-Event-ID" => t.listener.last_event_id)
    end
    append!(hs, t.headers)
    return hs
end

# Abandon the in-flight GET. The loop notices the transport is closed and stops
# on its own, but only once its blocking read returns, and an idle stream gives it
# no reason to.
function _stop_listening!(t::StreamableHTTPTransport)
    ctx, stream, task = @lock t.lock (t.listener.ctx, t.listener.stream, t.listener.task)
    ctx === nothing || try
        HTTP.cancel!(ctx; message = "the MCP transport was closed")
    catch
    end
    # Closing can itself block on a wedged connection, so it does not happen on
    # the task calling `close`.
    stream === nothing || @async (
        try
            close(stream)
        catch end
    )
    task === nothing || _wait_task(task, 1.0)
    return nothing
end

"""
    close(t::StreamableHTTPTransport)

Mark the transport unusable and, when the server issued a session id, ask it to
end the session with an HTTP `DELETE`. Failure to delete is logged at debug level
only: the session will expire on its own and there is nothing useful a caller can
do about it.

Any request still in flight fails with [`MCPTransportError`](@ref) rather than
waiting out its deadline, which matters most when that deadline is "never".
"""
function Base.close(t::StreamableHTTPTransport)
    already = @lock t.lock begin
        was = t.closed
        t.closed = true
        was
    end
    already && return nothing
    # Wake anyone mid-exchange before the session teardown, which itself performs
    # a request and can block.
    fail_pending!(
        t.pending, t.lock, MCPTransportError(
            "the transport for $(t.url) was closed while the request was in flight"
        )
    )
    # Before the DELETE, so a listener cannot re-establish a stream against a
    # session we are about to end.
    _stop_listening!(t)
    try
        _terminate_session(t)
    finally
        # The pooled connections go regardless of whether the server accepted the
        # session termination.
        try
            close(t.http_client)
        catch
        end
    end
    return nothing
end

function _terminate_session(t::StreamableHTTPTransport)
    sid, version = @lock t.lock (t.session_id, t.protocol_version)
    (t.terminate_on_close && sid !== nothing) || return nothing
    headers = Pair{String, String}["Mcp-Session-Id" => sid]
    version === nothing || push!(headers, "MCP-Protocol-Version" => version)
    append!(headers, t.headers)
    # `timeout <= 0` means "wait forever" (see `await_deadline`), so the DELETE
    # gets a capped deadline either way.
    deadline = t.timeout > 0 ? min(t.timeout, 5.0) : 5.0
    try
        d = Deadline()
        @async begin
            try
                HTTP.request(
                    "DELETE", t.url, headers; retry = false, status_exception = false,
                    client = t.http_client
                )
                deliver!(d, nothing)
            catch e
                deliver!(d, e isa Exception ? e : ErrorException(string(e)))
            end
        end
        await_deadline(d, deadline, "DELETE")
    catch e
        @debug "could not terminate MCP session" exception = e
    end
    return nothing
end
