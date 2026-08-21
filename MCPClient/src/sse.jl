# A minimal Server-Sent Events frame parser.
#
# MCP servers may answer a POST with `Content-Type: text/event-stream` instead of
# plain JSON, and each event's `data` field is then one JSON-RPC message. HTTP.jl
# gained its own SSE helpers only recently, so parsing the handful of relevant
# fields here keeps this package working across HTTP.jl versions and keeps the
# parser directly testable without a socket.
#
# Only `event` and `data` are modelled. `id` and `retry` exist to drive
# reconnection, which this client does not do, and a field nobody reads is
# indistinguishable from one that is ignored.

"""
    SSEEvent(event, data)

One dispatched SSE event. `data` holds the `data:` lines joined with newlines,
matching the browser EventSource semantics that MCP servers are written against.
"""
struct SSEEvent
    event::Union{Nothing, String}
    data::String
end

mutable struct SSEParser
    data::Vector{String}
    event::Union{Nothing, String}
    saw_data::Bool
end

SSEParser() = SSEParser(String[], nothing, false)

function _reset!(p::SSEParser)
    empty!(p.data)
    p.event = nothing
    p.saw_data = false
    return nothing
end

"""
    feed_line!(parser, line) -> Union{Nothing,SSEEvent}

Feed one line, stripped of its terminator, and get back an event when that line
was the blank line that dispatches one. A line beginning with `:` is a comment,
which servers use as a keep-alive heartbeat, so it must not dispatch anything.
"""
function feed_line!(p::SSEParser, line::AbstractString)
    line = endswith(line, '\r') ? chop(line) : line
    if isempty(line)
        # The spec discards an event whose data buffer was never written to, so a
        # lone `id:` line followed by a blank line is bookkeeping, not a message.
        if !p.saw_data
            _reset!(p)
            return nothing
        end
        ev = SSEEvent(p.event, join(p.data, "\n"))
        _reset!(p)
        return ev
    end
    startswith(line, ':') && return nothing
    colon = findfirst(==(':'), line)
    if colon === nothing
        field, value = line, ""
    else
        field = line[1:prevind(line, colon)]
        value = line[nextind(line, colon):end]
        startswith(value, ' ') && (value = value[2:end])
    end
    if field == "data"
        push!(p.data, value)
        p.saw_data = true
    elseif field == "event"
        p.event = value
    end
    return nothing
end

"""
    parse_sse(text) -> Vector{SSEEvent}

Parse a complete SSE body in one call. The transport streams
[`feed_line!`](@ref) line by line instead; this exists to exercise the parser
directly.
"""
function parse_sse(text::AbstractString)
    p = SSEParser()
    events = SSEEvent[]
    for line in split(text, '\n')
        ev = feed_line!(p, line)
        ev === nothing || push!(events, ev)
    end
    # A body that ends without a trailing blank line leaves one event pending.
    ev = feed_line!(p, "")
    ev === nothing || push!(events, ev)
    return events
end
