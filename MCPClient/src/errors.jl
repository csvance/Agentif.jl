# Every failure mode a caller may want to distinguish gets its own type, because
# "the server said no" and "the server never answered" call for different
# recovery: the first is usually a bad argument, the second a dead endpoint.

"""
    MCPException

Supertype of every exception raised by MCPClient. Catching this catches
transport failures, timeouts, protocol violations and JSON-RPC errors alike.
"""
abstract type MCPException <: Exception end

"""
    JSONRPCError(code, message, data, method)

A JSON-RPC 2.0 `error` object returned by the server, carrying its numeric
`code`, human-readable `message` and free-form `data` payload. `method` records
the request that produced it, which the wire format does not include.

Note that a *tool* reporting failure is not this: a failing tool returns a
normal result with `is_error` set, see [`ToolResult`](@ref). This type means the
request itself was rejected.
"""
struct JSONRPCError <: MCPException
    code::Int
    message::String
    data::Any
    method::String
end

# The two reserved JSON-RPC 2.0 codes this client sends. Servers add their own
# outside the reserved range.
const ERR_METHOD_NOT_FOUND = -32601
const ERR_INTERNAL = -32603

function Base.showerror(io::IO, e::JSONRPCError)
    print(io, "JSONRPCError: ")
    isempty(e.method) || print(io, e.method, " failed: ")
    print(io, e.message, " (code ", e.code, ")")
    return e.data === nothing || print(io, "; data=", e.data)
end

"""
    MCPTimeoutError(method, timeout)

The peer did not produce a reply to `method` within `timeout` seconds.

MCPClient stopped waiting, and told the server so by sending the specification's
`notifications/cancelled` for that request id, so a server that honours it stops
working too. Whether it does is the server's business: the request may still be
executing when this is thrown.
"""
struct MCPTimeoutError <: MCPException
    method::String
    timeout::Float64
end

Base.showerror(io::IO, e::MCPTimeoutError) =
    print(io, "MCPTimeoutError: no reply to \"", e.method, "\" within ", e.timeout, "s")

"""
    MCPTransportError(message, cause)

The message could not be exchanged at all: connection refused, a non-2xx HTTP
status, a closed session, a truncated body. `cause` is the underlying exception
when there was one, otherwise `nothing`.
"""
struct MCPTransportError <: MCPException
    message::String
    cause::Any
end

MCPTransportError(message::AbstractString) = MCPTransportError(String(message), nothing)

function Base.showerror(io::IO, e::MCPTransportError)
    print(io, "MCPTransportError: ", e.message)
    return e.cause === nothing || print(io, " (caused by ", sprint(showerror, e.cause), ")")
end

"""
    MCPProtocolError(message)

The peer spoke, but not MCP: a reply with no `result` and no `error`, a content
block missing its `type`, an unsupported protocol version, a paginated list that
never terminates.
"""
struct MCPProtocolError <: MCPException
    message::String
end

Base.showerror(io::IO, e::MCPProtocolError) = print(io, "MCPProtocolError: ", e.message)
