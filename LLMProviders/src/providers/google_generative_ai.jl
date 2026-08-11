module GoogleGenerativeAI

using StructUtils, JSON
using ..GoogleShared: sanitize_schema, schema, FunctionDeclaration, Tool, FunctionCall,
    InlineData, FunctionResponse, Part, Content, Candidate, UsageMetadata

@omit_null @kwarg struct GenerateContentResponse
    candidates::Union{Nothing, Vector{Candidate}} = nothing
    responseId::Union{Nothing, String} = nothing
    usageMetadata::Union{Nothing, UsageMetadata} = nothing
end

@omit_null @kwarg struct Request
    contents::Vector{Content}
    tools::Union{Nothing, Vector{Tool}} = nothing
    systemInstruction::Union{Nothing, Content} = nothing
    toolConfig::Union{Nothing, Any} = nothing
end

end # module GoogleGenerativeAI
