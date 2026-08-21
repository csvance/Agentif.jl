# Streamable HTTP transport (MCP revision 2025-03-26 onwards).
#
# One endpoint URL takes every message by POST. The interesting wrinkle is that a
# single POST may be answered in either of two ways: a plain `application/json`
# body holding one JSON-RPC response, or a `text/event-stream` body on which the
# server may emit progress notifications and its own requests before the response
# we are waiting for. Both are handled here so the layer above sees only a
# response dictionary.

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
"""
mutable struct StreamableHTTPTransport <: AbstractTransport
    url::String
    headers::Vector{Pair{String,String}}
    timeout::Float64
    session_id::Union{Nothing,String}
    protocol_version::Union{Nothing,String}
    handler::Any
    closed::Bool
    terminate_on_close::Bool
    http_client::HTTP.Client
    # Every exchange currently waiting for a reply, so `close` can wake it. A
    # closed socket does not by itself unblock the caller: its `Deadline` lives
    # on the worker task, so without this registry the caller waits out its full
    # timeout after `close` returns, and with `timeout <= 0` waits forever.
    inflight::Dict{Int,Deadline}
    next_inflight::Int
    lock::ReentrantLock
end

function StreamableHTTPTransport(url::AbstractString;
                                headers=Pair{String,String}[],
                                timeout::Real=DEFAULT_TIMEOUT,
                                terminate_on_close::Bool=true)
    hs = Pair{String,String}[String(k) => String(v) for (k, v) in headers]
    # One client per transport: its connection pool keeps a session's calls off a
    # fresh TCP (and TLS) handshake each time, which otherwise dominates the cost
    # of a small tools/call.
    return StreamableHTTPTransport(String(url), hs, Float64(timeout), nothing, nothing,
                                   nothing, false, terminate_on_close, HTTP.Client(),
                                   Dict{Int,Deadline}(), 0, ReentrantLock())
end

session_id(t::StreamableHTTPTransport) = @lock t.lock t.session_id

"""
    protocol_version!(t, version)

Record the negotiated protocol version so it can be sent as the
`MCP-Protocol-Version` header, which servers use to keep older clients working.
"""
protocol_version!(t::StreamableHTTPTransport, version::AbstractString) =
    @lock t.lock (t.protocol_version = String(version))

Base.show(io::IO, t::StreamableHTTPTransport) =
    print(io, "StreamableHTTPTransport(", t.url, t.closed ? ", closed" : "", ")")

function _request_headers(t::StreamableHTTPTransport)
    hs = Pair{String,String}[
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

function send_request!(t::StreamableHTTPTransport, message::AbstractDict, id;
                       timeout::Real=t.timeout)
    method = String(get(message, "method", "?"))
    is_open(t) || throw(MCPTransportError("transport for $(t.url) is closed"))
    reply = _exchange(t, message, id, timeout, method)
    reply === nothing && throw(MCPProtocolError(
        "the server accepted \"$method\" without answering it; a request must get a response"))
    return reply
end

function send_notification!(t::StreamableHTTPTransport, message::AbstractDict;
                            timeout::Real=t.timeout)
    method = String(get(message, "method", "?"))
    is_open(t) || throw(MCPTransportError("transport for $(t.url) is closed"))
    _exchange(t, message, nothing, timeout, method)
    return nothing
end

# Perform one POST. Returns the response matching `want_id`, or nothing when
# there was none (the normal outcome for a notification, which servers answer
# with 202 Accepted and an empty body).
function _exchange(t::StreamableHTTPTransport, message::AbstractDict, want_id,
                   timeout::Real, method::AbstractString)
    payload = JSON.json(message)
    stream_ref = Ref{Any}(nothing)
    # A RequestContext is how HTTP.jl is told to abandon a request that is still
    # in flight, which releases the pooled connection instead of leaking it.
    ctx = HTTP.RequestContext()
    cleanup = function ()
        try
            HTTP.cancel!(ctx; message="MCP request timed out")
        catch
        end
        s = stream_ref[]
        # Closing can itself block on a wedged connection, so never do it on the
        # caller's task.
        s === nothing || @async (try close(s) catch end)
        return nothing
    end
    return run_with_deadline(timeout, method; cleanup=cleanup) do d
        token = _register_inflight!(t, d, method)
        try
            _post(t, payload, want_id, method, stream_ref, ctx, d)
        finally
            _unregister_inflight!(t, token)
        end
    end
end

function _register_inflight!(t::StreamableHTTPTransport, d::Deadline, method::AbstractString)
    # Registering the waiter and re-checking `closed` happen under one lock, and
    # `close` empties the registry under the same one, so a request registered
    # just after a close cannot be stranded.
    @lock t.lock begin
        t.closed && throw(MCPTransportError("transport for $(t.url) was closed before \"$method\" was sent"))
        t.next_inflight += 1
        token = t.next_inflight
        t.inflight[token] = d
        return token
    end
end

_unregister_inflight!(t::StreamableHTTPTransport, token::Int) =
    @lock t.lock delete!(t.inflight, token)

function _fail_inflight!(t::StreamableHTTPTransport, err::Exception)
    waiters = @lock t.lock begin
        ws = collect(values(t.inflight))
        empty!(t.inflight)
        ws
    end
    for d in waiters
        deliver!(d, err)
    end
    return nothing
end

function _post(t::StreamableHTTPTransport, payload::String, want_id, method::AbstractString,
               stream_ref::Ref{Any}, ctx, d::Deadline)
    # retry=false: a JSON-RPC request is not idempotent, and a retried tools/call
    # could run a side effect twice. status_exception=false: a non-2xx body often
    # explains what went wrong and is worth putting in the error message.
    try
        HTTP.open("POST", t.url, _request_headers(t); retry=false, status_exception=false,
                  context=ctx, client=t.http_client) do stream
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
        throw(MCPTransportError(
            "MCP session $(session_id(t)) is no longer valid (HTTP 404); open a new client"))
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

function _read_sse!(t::StreamableHTTPTransport, stream, want_id, d::Deadline)
    parser = SSEParser()
    while !eof(stream)
        line = readline(stream)
        event = feed_line!(parser, line)
        event === nothing && continue
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
    _fail_inflight!(t, MCPTransportError(
        "the transport for $(t.url) was closed while the request was in flight"))
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
    headers = Pair{String,String}["Mcp-Session-Id" => sid]
    version === nothing || push!(headers, "MCP-Protocol-Version" => version)
    append!(headers, t.headers)
    try
        run_with_deadline(t.timeout <= 0 ? 5.0 : min(t.timeout, 5.0), "DELETE") do d
            HTTP.request("DELETE", t.url, headers; retry=false, status_exception=false,
                         client=t.http_client)
            deliver!(d, nothing)
        end
    catch e
        @debug "could not terminate MCP session" exception = e
    end
    return nothing
end
