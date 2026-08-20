# JSON-RPC 2.0 framing, shared by every transport. Nothing here knows about
# HTTP, sockets or processes; a transport's only job is to move these
# dictionaries between two endpoints.

const JSONRPC_VERSION = "2.0"

"""
    plain(x)

Recursively convert parsed JSON into plain Julia containers. JSON.jl hands back
a `JSON.Object`, which is an `AbstractDict` but not a `Dict`; converting once at
the boundary means every value this package exposes is a `Dict{String,Any}`,
`Vector{Any}`, `String`, number, `Bool` or `nothing`, so callers never have to
care which JSON package produced it.
"""
plain(x) = x
plain(x::AbstractDict) = Dict{String,Any}(String(k) => plain(v) for (k, v) in x)
plain(x::AbstractVector) = Any[plain(v) for v in x]

function request_message(id, method::AbstractString, params)
    msg = Dict{String,Any}("jsonrpc" => JSONRPC_VERSION, "id" => id, "method" => String(method))
    params === nothing || (msg["params"] = params)
    return msg
end

function notification_message(method::AbstractString, params)
    msg = Dict{String,Any}("jsonrpc" => JSONRPC_VERSION, "method" => String(method))
    params === nothing || (msg["params"] = params)
    return msg
end

result_message(id, result) =
    Dict{String,Any}("jsonrpc" => JSONRPC_VERSION, "id" => id, "result" => result)

function error_message(id, code::Integer, message::AbstractString, data=nothing)
    err = Dict{String,Any}("code" => Int(code), "message" => String(message))
    data === nothing || (err["data"] = data)
    return Dict{String,Any}("jsonrpc" => JSONRPC_VERSION, "id" => id, "error" => err)
end

is_response(msg::AbstractDict) = haskey(msg, "id") && (haskey(msg, "result") || haskey(msg, "error"))
is_request(msg::AbstractDict) = haskey(msg, "method") && haskey(msg, "id") && msg["id"] !== nothing
is_notification(msg::AbstractDict) = haskey(msg, "method") && get(msg, "id", nothing) === nothing

"""
    ids_equal(a, b)

Compare JSON-RPC ids. Ids are opaque strings or numbers and a server may echo
`1` as `1.0` or `"1"` after a JSON round trip, so compare by string form when
the types differ rather than dropping a reply we asked for.
"""
function ids_equal(a, b)
    (a === nothing || b === nothing) && return false
    a == b && return true
    return _id_string(a) == _id_string(b)
end

_id_string(x::Integer) = string(x)
_id_string(x::AbstractFloat) = isinteger(x) ? string(Integer(x)) : string(x)
_id_string(x) = string(x)

"""
    unwrap_result(msg, method) -> Any

Turn a JSON-RPC response into the value it carries, mapping an `error` object to
a thrown [`JSONRPCError`](@ref).
"""
function unwrap_result(msg::AbstractDict, method::AbstractString)
    if haskey(msg, "error")
        err = msg["error"]
        err isa AbstractDict || throw(MCPProtocolError("\"error\" member of a response to \"$method\" is not an object"))
        code = get(err, "code", ERR_INTERNAL)
        throw(JSONRPCError(
            code isa Integer ? Int(code) : ERR_INTERNAL,
            String(get(err, "message", "unknown error")),
            plain(get(err, "data", nothing)),
            String(method),
        ))
    end
    haskey(msg, "result") ||
        throw(MCPProtocolError("response to \"$method\" has neither \"result\" nor \"error\""))
    return plain(msg["result"])
end

"""
    parse_payload(body) -> Vector{Dict{String,Any}}

Parse a JSON-RPC body into a list of messages. A single message and a batch
array both arrive on the same wire, so callers get a list either way.
"""
function parse_payload(body::AbstractString)
    parsed = try
        JSON.parse(body)
    catch e
        throw(MCPProtocolError("peer sent a body that is not valid JSON: " * sprint(showerror, e)))
    end
    if parsed isa AbstractDict
        return Dict{String,Any}[plain(parsed)]
    elseif parsed isa AbstractVector
        msgs = Dict{String,Any}[]
        for m in parsed
            m isa AbstractDict || throw(MCPProtocolError("JSON-RPC batch contains a non-object element"))
            push!(msgs, plain(m))
        end
        return msgs
    end
    throw(MCPProtocolError("JSON-RPC payload is neither an object nor an array"))
end
