@kwarg struct AgentTool{F, T}
    name::String
    description::Union{Nothing, String} = nothing
    strict::Bool = true
    func::F
end

parameters(::AgentTool{F, T}) where {F, T} = T
tool_name(tool::AgentTool) = tool.name
tool_name(name::AbstractString) = String(name)

const EmptyAgentTool = AgentTool{typeof(identity), @NamedTuple{}}
empty_agent_tools() = EmptyAgentTool[]

@kwarg mutable struct PendingToolCall
    const call_id::String
    const name::String
    arguments::String
end

tool_name(tool::PendingToolCall) = tool.name

function findtool(tools, name)
    tool = tryfindtool(tools, name)
    tool === nothing && throw(ArgumentError("invalid tool for agent: `$name`"))
    return tool
end

# Non-throwing findtool: returns `nothing` when `name` is not in `tools`.
# Stream-side call sites use this as a sentinel — a miss must not kill the
# stream, it must flow through as a ToolCallRequestEvent and arrive at the
# model as an error tool result (see `invalid_tool_result`).
function tryfindtool(tools, name)
    for tool in tools
        tool.name == name && return tool
    end
    return nothing
end

# Levenshtein edit distance (two-row DP) between two strings.
function levenshtein_distance(a::AbstractString, b::AbstractString)
    la, lb = length(a), length(b)
    la == 0 && return lb
    lb == 0 && return la
    # Shifted 1-based DP: array index j stores the distance to the prefix of length j-1.
    prev = collect(UInt16.(0:lb))
    curr = zeros(UInt16, lb + 1)
    for i in 1:la
        curr[1] = i
        for j in 2:lb + 1
            cost = a[i] == b[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[lb + 1]
end

# Closest registered tool name to `name`, for a suggestion in an error result.
# Preference order: exact → substring/prefix in either direction (covers the
# production failure where a model copied `check_eval` out of an in-band
# message while the registered name was `kaimon__check_eval`) → edit distance.
# Returns nothing when nothing is close enough to be a useful suggestion.
function closest_tool_match(tool_names, name)
    isempty(tool_names) && return nothing
    for t in tool_names
        t == name && return t
    end
    lname = lowercase(name)
    # Substring/prefix match in either direction
    best_sub = nothing
    best_sub_diff = 0
    for t in tool_names
        lt = lowercase(t)
        contains(lt, lname) || contains(lname, lt) || continue
        diff = abs(length(t) - length(name))
        if best_sub === nothing || diff < best_sub_diff || (diff == best_sub_diff && length(t) < length(best_sub))
            best_sub, best_sub_diff = t, diff
        end
    end
    best_sub !== nothing && return best_sub
    # Fall back to edit distance
    best = nothing
    best_dist = typemax(Int)
    for t in tool_names
        d = levenshtein_distance(name, t)
        if d < best_dist || (d == best_dist && length(t) < length(best))
            best, best_dist = t, d
        end
    end
    # Only suggest when the names actually agree on most of their length
    max_len = max(length(name), length(best))
    best_dist > max_len ÷ 2 && return nothing
    return best
end

function extract_function_args(func_expr::Expr)
    args = Symbol[]
    types = Any[]
    if func_expr.head === :call
        # Short form: f(x::T1, y::T2) = ...
        for i in 2:length(func_expr.args)
            arg = func_expr.args[i]
            if arg isa Symbol
                push!(args, arg)
                push!(types, :Any)
            elseif arg isa Expr && arg.head === :(::)
                if length(arg.args) == 1
                    push!(args, arg.args[1])
                    push!(types, :Any)
                else
                    push!(args, arg.args[1])
                    push!(types, arg.args[2])
                end
            elseif arg isa Expr && arg.head === :kw
                # Keyword argument: x::T = default
                if arg.args[1] isa Expr && arg.args[1].head === :(::)
                    if length(arg.args[1].args) == 1
                        push!(args, arg.args[1].args[1])
                        push!(types, :Any)
                    else
                        push!(args, arg.args[1].args[1])
                        push!(types, arg.args[1].args[2])
                    end
                else
                    push!(args, arg.args[1])
                    push!(types, :Any)
                end
            end
        end
    elseif func_expr.head === :function || func_expr.head === :(=)
        # Long form: function f(x::T1, y::T2) ... end
        call_expr = func_expr.head === :function ? func_expr.args[1] : func_expr.args[1]
        if call_expr.head === :call
            for i in 2:length(call_expr.args)
                arg = call_expr.args[i]
                if arg isa Symbol
                    push!(args, arg)
                    push!(types, :Any)
                elseif arg isa Expr && arg.head === :(::)
                    if length(arg.args) == 1
                        push!(args, arg.args[1])
                        push!(types, :Any)
                    else
                        push!(args, arg.args[1])
                        push!(types, arg.args[2])
                    end
                elseif arg isa Expr && arg.head === :kw
                    # Keyword argument: x::T = default
                    if arg.args[1] isa Expr && arg.args[1].head === :(::)
                        if length(arg.args[1].args) == 1
                            push!(args, arg.args[1].args[1])
                            push!(types, :Any)
                        else
                            push!(args, arg.args[1].args[1])
                            push!(types, arg.args[1].args[2])
                        end
                    else
                        push!(args, arg.args[1])
                        push!(types, :Any)
                    end
                end
            end
        end
    end
    return args, types
end

function extract_function_name(func_expr::Expr)
    if func_expr.head === :call
        return func_expr.args[1]
    elseif func_expr.head === :function || func_expr.head === :(=)
        call_expr = func_expr.head === :function ? func_expr.args[1] : func_expr.args[1]
        if call_expr.head === :call
            return call_expr.args[1]
        end
    end
    error("Could not extract function name from expression")
end

macro tool(description::String, func_expr::Expr)
    func_name = extract_function_name(func_expr)
    args, types = extract_function_args(func_expr)
    # Build NamedTuple type: @NamedTuple{arg1::T1, arg2::T2, ...}
    named_tuple_fields = Expr[]
    for (arg, typ) in zip(args, types)
        push!(named_tuple_fields, Expr(:(::), arg, typ))
    end
    named_tuple_type = if isempty(named_tuple_fields)
        :(@NamedTuple{})
    else
        Expr(:macrocall, Symbol("@NamedTuple"), nothing, Expr(:braces, named_tuple_fields...))
    end
    # Generate function definition and AgentTool construction
    return quote
        # Original function definition
        $(esc(func_expr))
        # AgentTool construction
        Agentif.AgentTool{typeof($(esc(func_name))), $named_tuple_type}(
            name = string($(Meta.quot(func_name))),
            description = $(description),
            func = $(esc(func_name))
        )
    end
end
