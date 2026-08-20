# Tool results in MCP are a list of typed content blocks, not a string. Callers
# almost always want the text, so `content_text` makes that one call, but the
# blocks are kept in full: an image or an embedded resource is data the caller
# may need, and throwing it away here would make it unrecoverable.

"""
    ContentBlock

One element of a tool result or prompt message. Every concrete block keeps the
`raw` dictionary it was parsed from, so fields this package does not model
(annotations, `_meta`, vendor extensions) remain reachable.
"""
abstract type ContentBlock end

"""
    TextContent(text, raw)

A `text` content block.
"""
struct TextContent <: ContentBlock
    text::String
    raw::Dict{String,Any}
end

"""
    ImageContent(data, mime_type, raw)

An `image` block. `data` holds the decoded bytes; the original base64 string is
still in `raw["data"]`.
"""
struct ImageContent <: ContentBlock
    data::Vector{UInt8}
    mime_type::String
    raw::Dict{String,Any}
end

"""
    AudioContent(data, mime_type, raw)

An `audio` block, structured exactly like [`ImageContent`](@ref).
"""
struct AudioContent <: ContentBlock
    data::Vector{UInt8}
    mime_type::String
    raw::Dict{String,Any}
end

"""
    EmbeddedResource(uri, mime_type, text, blob, raw)

A `resource` block: resource contents inlined into the result. Exactly one of
`text` and `blob` is populated, matching which form the server sent.
"""
struct EmbeddedResource <: ContentBlock
    uri::String
    mime_type::Union{Nothing,String}
    text::Union{Nothing,String}
    blob::Union{Nothing,Vector{UInt8}}
    raw::Dict{String,Any}
end

"""
    ResourceLink(uri, name, description, mime_type, raw)

A `resource_link` block: a pointer to a resource the caller can fetch later,
carrying no contents of its own.
"""
struct ResourceLink <: ContentBlock
    uri::String
    name::String
    description::Union{Nothing,String}
    mime_type::Union{Nothing,String}
    raw::Dict{String,Any}
end

"""
    UnknownContent(type, raw)

A block whose `type` this package does not model. Newer spec revisions add block
types, and a client that errors on one it has not seen before is a client that
breaks on upgrade, so unknown blocks are preserved instead.
"""
struct UnknownContent <: ContentBlock
    type::String
    raw::Dict{String,Any}
end

# Kept as a thin alias so call sites read as intent rather than as plumbing.
_maybe_string(x, what::AbstractString) = want_string_or_nothing(x, what)

function _decode_b64(x, what::AbstractString)
    x isa AbstractString ||
        throw(MCPProtocolError("$what content block has no base64 \"data\" string"))
    try
        return base64decode(String(x))
    catch e
        throw(MCPProtocolError("$what content block holds invalid base64: " * sprint(showerror, e)))
    end
end

"""
    parse_content(block) -> ContentBlock

Turn one decoded JSON content block into its Julia representation.
"""
function parse_content(block::AbstractDict)
    raw = plain(block)
    kind = get(raw, "type", nothing)
    kind isa AbstractString || throw(MCPProtocolError("content block is missing its \"type\""))
    if kind == "text"
        return TextContent(want_string(get(raw, "text", ""), "\"text\" of a text content block"), raw)
    elseif kind == "image"
        return ImageContent(_decode_b64(get(raw, "data", nothing), "image"),
                            want_string(get(raw, "mimeType", "application/octet-stream"),
                                        "\"mimeType\" of an image content block"), raw)
    elseif kind == "audio"
        return AudioContent(_decode_b64(get(raw, "data", nothing), "audio"),
                            want_string(get(raw, "mimeType", "application/octet-stream"),
                                        "\"mimeType\" of an audio content block"), raw)
    elseif kind == "resource"
        res = get(raw, "resource", nothing)
        res isa AbstractDict ||
            throw(MCPProtocolError("resource content block has no \"resource\" object"))
        blob = get(res, "blob", nothing)
        blob === nothing || get(res, "text", nothing) === nothing ||
            throw(MCPProtocolError("resource content block carries both \"text\" and \"blob\""))
        return EmbeddedResource(want_string(get(res, "uri", ""), "\"resource.uri\""),
                                _maybe_string(get(res, "mimeType", nothing), "\"resource.mimeType\""),
                                _maybe_string(get(res, "text", nothing), "\"resource.text\""),
                                blob === nothing ? nothing : _decode_b64(blob, "resource"),
                                raw)
    elseif kind == "resource_link"
        return ResourceLink(want_string(get(raw, "uri", ""), "\"uri\" of a resource_link block"),
                            want_string(get(raw, "name", ""), "\"name\" of a resource_link block"),
                            _maybe_string(get(raw, "description", nothing),
                                          "\"description\" of a resource_link block"),
                            _maybe_string(get(raw, "mimeType", nothing),
                                          "\"mimeType\" of a resource_link block"), raw)
    end
    return UnknownContent(String(kind), raw)
end

parse_content(x) = throw(MCPProtocolError("content block is not an object, got $(typeof(x))"))

"""
    content_text(x) -> String

The text carried by a content block or a whole [`ToolResult`](@ref). Blocks with
no textual form contribute nothing, and a result's blocks are joined with
newlines, so this is the string to hand to a language model.
"""
content_text(b::ContentBlock) = ""
content_text(b::TextContent) = b.text
content_text(b::EmbeddedResource) = b.text === nothing ? "" : b.text

"""
    ToolResult

The outcome of [`call_tool`](@ref).

  * `content`: the content blocks, in order
  * `is_error`: the server's `isError` flag. A tool that fails is reported as
    data rather than as an exception, because the failure text is usually meant
    to go back to the model so it can try something else
  * `structured_content`: the tool's `structuredContent` object when it declares
    an output schema, otherwise `nothing`
  * `raw`: the full decoded result

Use [`content_text`](@ref) for the text.
"""
struct ToolResult
    content::Vector{ContentBlock}
    is_error::Bool
    structured_content::Union{Nothing,Dict{String,Any}}
    raw::Dict{String,Any}
end

function content_text(r::ToolResult)
    parts = String[]
    for block in r.content
        text = content_text(block)
        isempty(text) || push!(parts, text)
    end
    return join(parts, "\n")
end

function ToolResult(result::AbstractDict)
    raw = plain(result)
    blocks = ContentBlock[]
    content = get(raw, "content", nothing)
    if content isa AbstractVector
        for block in content
            push!(blocks, parse_content(block))
        end
    elseif content !== nothing
        throw(MCPProtocolError("tool result \"content\" is not an array"))
    end
    return ToolResult(blocks, get(raw, "isError", false) === true,
                      want_object_or_nothing(get(raw, "structuredContent", nothing),
                                             "\"structuredContent\" of a tool result"), raw)
end

function Base.show(io::IO, r::ToolResult)
    print(io, "ToolResult(", length(r.content), " block",
          length(r.content) == 1 ? "" : "s", r.is_error ? ", isError" : "", ")")
end

function Base.show(io::IO, ::MIME"text/plain", r::ToolResult)
    show(io, r)
    text = content_text(r)
    isempty(text) || print(io, "\n", _snippet(text, 2000))
end

"""
    MCPTool

A tool the server offers.

  * `name`: the identifier to pass to [`call_tool`](@ref)
  * `description`: prose for the model, empty when the server gave none
  * `input_schema`: the JSON Schema of the arguments object, as a plain `Dict`
  * `output_schema`: JSON Schema of `structuredContent`, when declared
  * `title`, `annotations`, `raw`: presentation hints and the untouched payload

The fields are plain Julia values so a wrapper can map them onto any agent
framework's tool type without unwrapping anything.
"""
struct MCPTool
    name::String
    description::String
    input_schema::Dict{String,Any}
    output_schema::Union{Nothing,Dict{String,Any}}
    title::Union{Nothing,String}
    annotations::Dict{String,Any}
    raw::Dict{String,Any}
end

function MCPTool(tool::AbstractDict)
    raw = plain(tool)
    name = get(raw, "name", nothing)
    name isa AbstractString || throw(MCPProtocolError("tool entry is missing its \"name\""))
    # An omitted inputSchema is a server that takes no arguments; a wrong-typed
    # one is a server whose arguments we would then get wrong, so it is an error.
    schema = get(raw, "inputSchema", nothing)
    annotations = get(raw, "annotations", nothing)
    return MCPTool(String(name),
                   want_string(get(raw, "description", ""), "\"description\" of tool \"$name\""),
                   schema === nothing ? Dict{String,Any}("type" => "object") :
                       want_object(schema, "\"inputSchema\" of tool \"$name\""),
                   want_object_or_nothing(get(raw, "outputSchema", nothing),
                                          "\"outputSchema\" of tool \"$name\""),
                   _maybe_string(get(raw, "title", nothing), "\"title\" of tool \"$name\""),
                   annotations === nothing ? Dict{String,Any}() :
                       want_object(annotations, "\"annotations\" of tool \"$name\""),
                   raw)
end

Base.show(io::IO, t::MCPTool) = print(io, "MCPTool(\"", t.name, "\")")
