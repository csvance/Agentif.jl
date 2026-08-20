# The protocol layer: everything here is transport independent.

"""
Protocol revision this client asks for. Servers may answer with an older one they
support, which is the negotiation MCP performs during `initialize`.
"""
const LATEST_PROTOCOL_VERSION = "2025-06-18"

"""
Revisions this client can speak. The differences that matter to a tool caller are
small; the list exists so an unrecognised version can be rejected rather than
silently mishandled.
"""
const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

"""
    Client(url; kwargs...)
    Client(command::Cmd; kwargs...)
    Client(transport; kwargs...)
    Client(f, url; kwargs...)

Connect to an MCP server and perform the `initialize` handshake.

Passing a URL builds a [`StreamableHTTPTransport`](@ref) and passing a `Cmd`
builds a [`StdioTransport`](@ref), which runs the server as a child process; pass
a transport directly to configure it further or to use another one. The
two-argument form runs `f` with the client and closes it afterwards, even if `f`
throws.

Keyword arguments:

  * `headers`: extra HTTP headers, for example `["Authorization" => "Bearer ..."]`
    (HTTP only)
  * `env`, `dir`, `inherit_env`: the child process's environment and working
    directory (`Cmd` only), see [`StdioTransport`](@ref)
  * `timeout`: per-request deadline in seconds, default 30; `<= 0` waits forever
  * `name`, `version`: how this client identifies itself to the server
  * `capabilities`: client capabilities to advertise, default none. This client
    implements no sampling, roots or elicitation, so declaring them would be a
    promise it cannot keep
  * `protocol_version`: the revision to request, default [`LATEST_PROTOCOL_VERSION`](@ref)
  * `strict_version`: throw when the server picks a revision this client does not
    list, which is what the spec asks a client to do. Set `false` to continue
    with a warning
  * `on_notification`: `f(message)` for server notifications such as
    `notifications/tools/list_changed`. Handlers run in order on one dedicated
    task, so a handler may call back into the client, and a slow one delays later
    notifications but never the transport
  * `on_request`: `f(method, params) -> result` for server-initiated requests.
    Without one, everything except `ping` is answered "method not found"
  * `initialize`: set `false` to construct without handshaking, then call
    [`initialize!`](@ref) yourself

# Example

```julia
client = Client("http://127.0.0.1:8931/mcp")
tools = list_tools(client)
result = call_tool(client, "search", Dict{String,Any}("query" => "julia"))
println(content_text(result))
close(client)
```
"""
mutable struct Client
    transport::AbstractTransport
    name::String
    version::String
    capabilities::Dict{String,Any}
    requested_version::String
    protocol_version::String
    server_info::Dict{String,Any}
    server_capabilities::Dict{String,Any}
    instructions::Union{Nothing,String}
    initialized::Bool
    timeout::Float64
    strict_version::Bool
    on_notification::Union{Nothing,Any}
    on_request::Union{Nothing,Any}
    next_id::Int
    lock::ReentrantLock
    # Server-initiated traffic is handled off the reader task; see `_incoming`.
    notifications::Union{Nothing,Channel{Any}}
    answered::Int
end

function Client(transport::AbstractTransport;
                name::AbstractString="MCPClient.jl",
                version::AbstractString="0.1.0",
                capabilities::AbstractDict=Dict{String,Any}(),
                protocol_version::AbstractString=LATEST_PROTOCOL_VERSION,
                strict_version::Bool=true,
                timeout::Real=DEFAULT_TIMEOUT,
                on_notification=nothing,
                on_request=nothing,
                initialize::Bool=true)
    client = Client(transport, String(name), String(version), plain(capabilities),
                    String(protocol_version), String(protocol_version),
                    Dict{String,Any}(), Dict{String,Any}(), nothing, false,
                    Float64(timeout), strict_version, on_notification, on_request,
                    0, ReentrantLock(), nothing, 0)
    set_handler!(transport, msg -> _incoming(client, msg))
    if initialize
        try
            initialize!(client)
        catch
            # A handshake that fails still leaves a socket, and possibly a session
            # or a child process, behind. The URL and `Cmd` constructors below
            # each guard this too; the guard belongs here as well, because a
            # caller who built the transport itself gets no other cleanup.
            close(client)
            rethrow()
        end
    end
    return client
end

function Client(url::AbstractString;
                headers=Pair{String,String}[],
                timeout::Real=DEFAULT_TIMEOUT,
                terminate_on_close::Bool=true,
                kwargs...)
    transport = StreamableHTTPTransport(url; headers=headers, timeout=timeout,
                                        terminate_on_close=terminate_on_close)
    try
        return Client(transport; timeout=timeout, kwargs...)
    catch
        # A handshake that fails still leaves a socket and possibly a session
        # behind on the server.
        close(transport)
        rethrow()
    end
end

function Client(command::Base.Cmd;
                env=nothing,
                dir=nothing,
                inherit_env::Bool=true,
                timeout::Real=DEFAULT_TIMEOUT,
                kwargs...)
    transport = StdioTransport(command; env=env, dir=dir, inherit_env=inherit_env,
                               timeout=timeout)
    try
        return Client(transport; timeout=timeout, kwargs...)
    catch
        # A handshake that fails still leaves a child process running, and an
        # orphaned MCP server holds whatever the real one would have held.
        close(transport)
        rethrow()
    end
end

function Client(f::Function, url_or_transport; kwargs...)
    # Construction is outside the `try` on purpose: if it throws, it has already
    # cleaned up after itself and there is no client to close.
    client = Client(url_or_transport; kwargs...)
    try
        return f(client)
    finally
        close(client)
    end
end

function Base.show(io::IO, c::Client)
    print(io, "Client(")
    if c.initialized
        print(io, get(c.server_info, "name", "unknown server"))
        v = get(c.server_info, "version", nothing)
        v === nothing || print(io, " ", v)
        print(io, ", protocol ", c.protocol_version)
    else
        print(io, "not initialized")
    end
    print(io, ")")
end

"""
    server_info(c) -> Dict{String,Any}

The server's `name`, `version` and optional `title`, as reported by `initialize`.
"""
server_info(c::Client) = c.server_info

"""
    server_capabilities(c) -> Dict{String,Any}

What the server declared it supports, for example
`Dict("tools" => Dict("listChanged" => true))`.
"""
server_capabilities(c::Client) = c.server_capabilities

"""
    server_instructions(c) -> Union{Nothing,String}

Free-form usage guidance from the server, meant to be handed to the model as a
system-prompt fragment.
"""
server_instructions(c::Client) = c.instructions

"""
    protocol_version(c) -> String

The revision actually negotiated, which may be older than the one requested.
"""
protocol_version(c::Client) = c.protocol_version

"""
    session_id(c) -> Union{Nothing,String}

The transport's session identity, `Mcp-Session-Id` for streamable HTTP.
"""
session_id(c::Client) = session_id(c.transport)

"""
    has_capability(c, name) -> Bool

Whether the server declared the top-level capability `name`, such as `"tools"`,
`"resources"` or `"prompts"`.
"""
has_capability(c::Client, name::AbstractString) = haskey(c.server_capabilities, String(name))

is_open(c::Client) = is_open(c.transport)

function _next_id!(c::Client)
    @lock c.lock begin
        c.next_id += 1
        return c.next_id
    end
end

"""
    request(c, method, params=nothing; timeout=c.timeout) -> Any

Send a JSON-RPC request and return its `result`. A JSON-RPC `error` response
becomes a thrown [`JSONRPCError`](@ref). Use this for methods this package does
not wrap.
"""
function request(c::Client, method::AbstractString, params=nothing; timeout::Real=c.timeout)
    id = _next_id!(c)
    message = request_message(id, method, params)
    response = send_request!(c.transport, message, id; timeout=timeout)
    return unwrap_result(response, method)
end

"""
    notify_server(c, method, params=nothing)

Send a notification, which by definition gets no reply and cannot fail at the
protocol level.
"""
function notify_server(c::Client, method::AbstractString, params=nothing)
    send_notification!(c.transport, notification_message(method, params))
    return nothing
end

"""
    initialize!(c; timeout=c.timeout) -> Client

Run the handshake: send `initialize`, check the version the server chose, record
its capabilities, then send the `notifications/initialized` acknowledgement that
tells the server the session is live. [`Client`](@ref) calls this for you.
"""
function initialize!(c::Client; timeout::Real=c.timeout)
    c.initialized && return c
    params = Dict{String,Any}(
        "protocolVersion" => c.requested_version,
        "capabilities" => c.capabilities,
        "clientInfo" => Dict{String,Any}("name" => c.name, "version" => c.version),
    )
    result = request(c, "initialize", params; timeout=timeout)
    result isa AbstractDict || throw(MCPProtocolError("initialize result is not an object"))
    version = get(result, "protocolVersion", nothing)
    version isa AbstractString ||
        throw(MCPProtocolError("initialize result has no \"protocolVersion\" string"))
    if !(version in SUPPORTED_PROTOCOL_VERSIONS)
        message = "server chose MCP protocol version \"$version\", which this client does not " *
                  "list as supported ($(join(SUPPORTED_PROTOCOL_VERSIONS, ", ")))"
        c.strict_version && throw(MCPProtocolError(message))
        @warn message
    end
    c.protocol_version = String(version)
    # A wrong-typed capabilities or serverInfo object used to become an empty one,
    # which makes a malformed server indistinguishable from a limited one and
    # sends `has_capability` answering `false` about a capability the server has.
    caps = get(result, "capabilities", nothing)
    c.server_capabilities = something(want_object_or_nothing(caps, "\"capabilities\" in the initialize result"),
                                      Dict{String,Any}())
    info = get(result, "serverInfo", nothing)
    c.server_info = something(want_object_or_nothing(info, "\"serverInfo\" in the initialize result"),
                              Dict{String,Any}())
    c.instructions = want_string_or_nothing(get(result, "instructions", nothing),
                                            "\"instructions\" in the initialize result")
    # Only after this point may the session id and protocol version headers ride
    # along, and only after the notification may the server expect other calls.
    protocol_version!(c.transport, c.protocol_version)
    notify_server(c, "notifications/initialized")
    c.initialized = true
    return c
end

"""
    ping(c; timeout=c.timeout) -> Nothing

Check that the peer is alive. Throws on failure, including
[`MCPTimeoutError`](@ref) when it does not answer in time.
"""
function ping(c::Client; timeout::Real=c.timeout)
    request(c, "ping", Dict{String,Any}(); timeout=timeout)
    return nothing
end

"""
    list_tools_page(c; cursor=nothing, timeout=c.timeout) -> (Vector{MCPTool}, Union{Nothing,String})

One page of `tools/list`, plus the cursor for the next page or `nothing` when the
listing is complete. Use [`list_tools`](@ref) unless you need to page manually.
"""
function list_tools_page(c::Client; cursor=nothing, timeout::Real=c.timeout)
    params = Dict{String,Any}()
    cursor === nothing || (params["cursor"] = String(cursor))
    result = request(c, "tools/list", params; timeout=timeout)
    result isa AbstractDict || throw(MCPProtocolError("tools/list result is not an object"))
    entries = get(result, "tools", nothing)
    entries isa AbstractVector ||
        throw(MCPProtocolError("tools/list result has no \"tools\" array"))
    tools = MCPTool[MCPTool(want_object(e, "an entry in the tools/list result")) for e in entries]
    next = get(result, "nextCursor", nothing)
    if next !== nothing && !(next isa AbstractString)
        throw(MCPProtocolError("tools/list returned a \"nextCursor\" that is not a string"))
    end
    return tools, next === nothing ? nothing : String(next)
end

"""
    list_tools(c; timeout=c.timeout, max_pages=100) -> Vector{MCPTool}

Every tool the server offers, following `nextCursor` until the listing ends.

`max_pages` bounds a server that paginates forever; hitting it, or seeing a
cursor repeat, raises [`MCPProtocolError`](@ref) rather than looping.
"""
function list_tools(c::Client; timeout::Real=c.timeout, max_pages::Integer=100)
    tools = MCPTool[]
    seen = Set{String}()
    cursor = nothing
    for _ in 1:max_pages
        page, cursor = list_tools_page(c; cursor=cursor, timeout=timeout)
        append!(tools, page)
        cursor === nothing && return tools
        cursor in seen &&
            throw(MCPProtocolError("tools/list repeated the cursor \"$cursor\"; the server is not making progress"))
        push!(seen, cursor)
    end
    throw(MCPProtocolError("tools/list did not finish within $max_pages pages"))
end

"""
    call_tool(c, name, arguments=Dict{String,Any}(); timeout=c.timeout) -> ToolResult

Invoke a tool and return its result.

A tool that reports failure comes back as a `ToolResult` with `is_error` set, not
as an exception: that text is normally fed back to the model. Exceptions are
reserved for the call not happening, for instance an unknown tool name
([`JSONRPCError`](@ref)) or a server that never replies
([`MCPTimeoutError`](@ref)).
"""
function call_tool(c::Client, name::AbstractString, arguments=Dict{String,Any}();
                   timeout::Real=c.timeout, progress_token=nothing)
    params = Dict{String,Any}("name" => String(name), "arguments" => _arguments(arguments))
    # A server may only emit `notifications/progress` for a request that carried a token, so a
    # caller that wants progress has to ask for it here. Anything the server sends back under this
    # token reaches `on_notification`, which is the only way to learn anything about a call that has
    # not returned yet: without it a long call is indistinguishable from a dead one.
    progress_token === nothing ||
        (params["_meta"] = Dict{String,Any}("progressToken" => progress_token))
    result = request(c, "tools/call", params; timeout=timeout)
    result isa AbstractDict || throw(MCPProtocolError("tools/call result is not an object"))
    return ToolResult(result)
end

_arguments(x::AbstractDict) = Dict{String,Any}(String(k) => v for (k, v) in x)
_arguments(x::NamedTuple) = Dict{String,Any}(String(k) => v for (k, v) in pairs(x))
_arguments(x) = throw(ArgumentError("tool arguments must be a dictionary or NamedTuple, got $(typeof(x))"))

"""
    close(c::Client)

End the session and release the transport. Safe to call more than once.
"""
function Base.close(c::Client)
    close(c.transport)
    channel = @lock c.lock begin
        ch = c.notifications
        c.notifications = nothing
        ch
    end
    # Closing the channel ends the pump once it has drained, so a notification
    # already queued still reaches its handler.
    channel === nothing || close(channel)
    return nothing
end

# --- server-initiated traffic ---------------------------------------------

"""
Server-initiated requests answered per session before the client stops replying.

A reply is itself a message, and over HTTP it is a fresh POST whose own response
body is routed straight back here, so a server that answers every POST with a
request gets an unbounded loop out of a client that always replies: measured at
roughly 700 replies per second, each with a task and a socket behind it. The
budget makes that terminate. It is far above any legitimate use, since the only
server-initiated request this client answers unprompted is `ping`.
"""
const MAX_ANSWERED_REQUESTS = 10_000

function _incoming(c::Client, msg::AbstractDict)
    if is_request(msg)
        # Answering means sending a message, which cannot happen on the task that
        # is reading the stream this request arrived on: over HTTP that would be a
        # POST from inside the response body being read, and over stdio the reader
        # task would be blocked while the reply it enables goes unread.
        _budget_exhausted(c) ? _refuse_request(c, msg) : @async _answer(c, msg)
    elseif is_notification(msg)
        _enqueue_notification(c, msg)
    end
    return nothing
end

function _budget_exhausted(c::Client)
    @lock c.lock begin
        c.answered >= MAX_ANSWERED_REQUESTS && return true
        c.answered += 1
        return false
    end
end

function _refuse_request(c::Client, msg::AbstractDict)
    # Logged once at the boundary rather than per request: a server in this state
    # is producing thousands, and the useful signal is that it happened at all.
    c.answered == MAX_ANSWERED_REQUESTS &&
        @warn "MCP server has sent $(MAX_ANSWERED_REQUESTS) requests on one session; ignoring further ones"
    @lock c.lock (c.answered += 1)
    return nothing
end

# Notifications run on one dedicated task, not on the reader task and not on a
# fresh task each. On the reader task, a handler that calls back into the client
# deadlocks the transport, since the task that would read its reply is the one
# inside the handler; a task each would let handlers overtake one another, which
# is wrong for an ordered progress stream. One consumer task keeps both
# properties.
function _enqueue_notification(c::Client, msg::AbstractDict)
    c.on_notification === nothing && return nothing
    channel = @lock c.lock begin
        if c.notifications === nothing
            ch = Channel{Any}(Inf)
            c.notifications = ch
            @async _drain_notifications(c, ch)
        end
        c.notifications
    end
    try
        put!(channel, msg)
    catch e
        # The only way this fails is a closed channel, which means the client is
        # shutting down and the notification no longer has anywhere to go.
        @debug "dropped a notification on a closing client" exception = e
    end
    return nothing
end

function _drain_notifications(c::Client, channel::Channel{Any})
    for msg in channel
        handler = c.on_notification
        handler === nothing && continue
        try
            handler(msg)
        catch e
            # A throwing handler must not kill the pump, or every later
            # notification is silently lost.
            @debug "on_notification handler failed" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

function _answer(c::Client, msg::AbstractDict)
    is_open(c) || return nothing
    id = get(msg, "id", nothing)
    method = String(get(msg, "method", ""))
    reply = try
        if method == "ping"
            # Answering ping is the one server-initiated request every client owes,
            # and a client that ignores it looks dead.
            result_message(id, Dict{String,Any}())
        elseif c.on_request === nothing
            error_message(id, ERR_METHOD_NOT_FOUND,
                          "this client does not implement \"$method\"")
        else
            result_message(id, c.on_request(method, plain(get(msg, "params", nothing))))
        end
    catch e
        @debug "on_request handler failed" exception = (e, catch_backtrace())
        error_message(id, ERR_INTERNAL, "client handler for \"$method\" failed: " * sprint(showerror, e))
    end
    try
        send_notification!(c.transport, reply)
    catch e
        @debug "could not deliver a response to a server-initiated request" exception = e
    end
    return nothing
end
