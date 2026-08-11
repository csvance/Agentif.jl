module GoogleGeminiCli

using StructUtils, JSON, UUIDs

import ..LLMProviders: Model
using ..GoogleShared: sanitize_schema, schema, FunctionDeclaration, Tool, FunctionCall,
    InlineData, FunctionResponse, Part, Content, Candidate, UsageMetadata

@omit_null @kwarg struct StreamResponse
    candidates::Union{Nothing, Vector{Candidate}} = nothing
    usageMetadata::Union{Nothing, UsageMetadata} = nothing
    modelVersion::Union{Nothing, String} = nothing
    responseId::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct StreamChunk
    response::Union{Nothing, StreamResponse} = nothing
    traceId::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct ThinkingConfig
    includeThoughts::Union{Nothing, Bool} = nothing
    thinkingBudget::Union{Nothing, Int} = nothing
    thinkingLevel::Union{Nothing, String} = nothing
end

@omit_null @kwarg struct GenerationConfig
    maxOutputTokens::Union{Nothing, Int} = nothing
    temperature::Union{Nothing, Float64} = nothing
    thinkingConfig::Union{Nothing, ThinkingConfig} = nothing
end

@omit_null @kwarg struct FunctionCallingConfig
    mode::String
end

@omit_null @kwarg struct ToolConfig
    functionCallingConfig::FunctionCallingConfig
end

@omit_null @kwarg struct RequestPayload
    contents::Vector{Content}
    systemInstruction::Union{Nothing, Content} = nothing
    generationConfig::Union{Nothing, GenerationConfig} = nothing
    tools::Union{Nothing, Vector{Tool}} = nothing
    toolConfig::Union{Nothing, ToolConfig} = nothing
end

@omit_null @kwarg struct Request
    project::String
    model::String
    request::RequestPayload
    userAgent::Union{Nothing, String} = nothing
    requestId::Union{Nothing, String} = nothing
end

const DEFAULT_ENDPOINT = "https://cloudcode-pa.googleapis.com"
const GEMINI_CLI_HEADERS = Dict(
    "User-Agent" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client" => "gl-node/22.17.0",
    "Client-Metadata" => JSON.json(
        Dict(
            "ideType" => "IDE_UNSPECIFIED",
            "platform" => "PLATFORM_UNSPECIFIED",
            "pluginType" => "GEMINI",
        )
    ),
)
const ANTIGRAVITY_HEADERS = Dict(
    "User-Agent" => "antigravity/1.11.5 darwin/arm64",
    "X-Goog-Api-Client" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "Client-Metadata" => JSON.json(
        Dict(
            "ideType" => "IDE_UNSPECIFIED",
            "platform" => "PLATFORM_UNSPECIFIED",
            "pluginType" => "GEMINI",
        )
    ),
)

function map_tool_choice(choice::String)
    if choice == "auto"
        return "AUTO"
    elseif choice == "none"
        return "NONE"
    elseif choice == "any"
        return "ANY"
    end
    return "AUTO"
end

function build_request(
        model::Model,
        contents::Vector{Content},
        project_id::String;
        systemInstruction::Union{Nothing, Content} = nothing,
        tools::Union{Nothing, Vector{Tool}} = nothing,
        toolChoice::Union{Nothing, String} = nothing,
        maxTokens::Union{Nothing, Int} = nothing,
        temperature::Union{Nothing, Float64} = nothing,
        thinking::Union{Nothing, Any} = nothing,
    )
    generation_config = nothing
    if temperature !== nothing || maxTokens !== nothing
        generation_config = GenerationConfig(; temperature = temperature, maxOutputTokens = maxTokens)
    end

    if thinking !== nothing
        enabled = false
        thinking_level = nothing
        thinking_budget = nothing
        if thinking isa NamedTuple
            enabled = haskey(thinking, :enabled) ? thinking.enabled : false
            thinking_level = haskey(thinking, :level) ? thinking.level : nothing
            thinking_budget = haskey(thinking, :budgetTokens) ? thinking.budgetTokens : nothing
        elseif thinking isa AbstractDict
            enabled = get(() -> false, thinking, "enabled")
            thinking_level = get(() -> nothing, thinking, "level")
            thinking_budget = get(() -> nothing, thinking, "budgetTokens")
        elseif hasproperty(thinking, :enabled)
            enabled = getproperty(thinking, :enabled)
            hasproperty(thinking, :level) && (thinking_level = getproperty(thinking, :level))
            hasproperty(thinking, :budgetTokens) && (thinking_budget = getproperty(thinking, :budgetTokens))
        end
        if enabled
            if thinking_level !== nothing
                thinking_config = ThinkingConfig(; includeThoughts = true, thinkingLevel = string(thinking_level))
            elseif thinking_budget !== nothing
                thinking_config = ThinkingConfig(; includeThoughts = true, thinkingBudget = thinking_budget)
            else
                thinking_config = ThinkingConfig(; includeThoughts = true)
            end
            generation_config = GenerationConfig(
                ; temperature = temperature,
                maxOutputTokens = maxTokens,
                thinkingConfig = thinking_config,
            )
        end
    end

    tool_config = nothing
    if toolChoice !== nothing
        tool_config = ToolConfig(; functionCallingConfig = FunctionCallingConfig(; mode = map_tool_choice(toolChoice)))
    end

    payload = RequestPayload(; contents, systemInstruction, generationConfig = generation_config, tools, toolConfig = tool_config)
    return Request(
        ; project = project_id,
        model = model.id,
        request = payload,
        userAgent = "agentif",
        requestId = "agentif-$(UUIDs.uuid4())",
    )
end

function parse_oauth_credentials(apikey::String)
    parsed = JSON.parse(apikey)
    token = get(() -> nothing, parsed, "token")
    project_id = get(() -> nothing, parsed, "projectId")
    return token, project_id
end

end # module GoogleGeminiCli
