# Model definitions and registry
# Ported from TypeScript models.ts and models.generated.ts

# Model type definitions
@kwarg struct ModelCostTier
    inputTokensAbove::Int
    input::Float64
    output::Float64
    cacheRead::Float64
    cacheWrite::Float64
end

@kwarg struct Model
    id::String
    name::String
    api::String  # "openai-responses", "openai-completions", "anthropic-messages", "google-generative-ai"
    provider::String
    baseUrl::String
    reasoning::Bool
    input::Vector{String}  # ["text"], ["text", "image"], etc.
    cost::Dict{String, Float64}  # input, output, cacheRead, cacheWrite (per million tokens)
    contextWindow::Int
    maxTokens::Int
    headers::Union{Nothing, Dict{String, String}} = nothing
    compat::Union{Nothing, Dict{String, Any}} = nothing
    kw::Any = (;) # additional keyword arguments that will be passed when api calls are made
    costTiers::Vector{ModelCostTier} = ModelCostTier[]
    thinkingLevelMap::Union{Nothing, Dict{String, Any}} = nothing
end

# Model registry - will be populated from models_generated.jl
const _model_registry = Dict{String, Dict{String, Model}}()

"""
    registerModel!(model::Model) -> Model

Register a model in the registry under its `provider` and `id`.
Overwrites any existing entry with the same provider/id.
"""
function registerModel!(model::Model)
    models = get!(() -> Dict{String, Model}(), _model_registry, model.provider)
    models[model.id] = model
    return model
end

"""
    getModel(provider::String, modelId::String) -> Union{Nothing,Model}

Get a model by provider and model ID.
"""
function getModel(provider::String, modelId::String)
    providerModels = get(() -> nothing, _model_registry, provider)
    providerModels === nothing && return nothing
    return get(() -> nothing, providerModels, modelId)
end

"""
    getProviders() -> Vector{String}

Get all available provider names.
"""
function getProviders()
    return collect(keys(_model_registry))
end

"""
    getModels(provider::String) -> Vector{Model}

Get all models for a given provider.
"""
function getModels(provider::String)
    providerModels = get(() -> Dict{String, Model}(), _model_registry, provider)
    return collect(values(providerModels))
end

"""
    calculateCost(model::Model, usage::Usage) -> Dict{String,Float64}

Calculate cost based on model pricing and usage.
Returns the cost dictionary with input, output, cacheRead, cacheWrite, and total.
"""
function calculateCost(model::Model, usage)
    input_rate = get(() -> 0.0, model.cost, "input")
    output_rate = get(() -> 0.0, model.cost, "output")
    cache_read_rate = get(() -> 0.0, model.cost, "cacheRead")
    cache_write_rate = get(() -> 0.0, model.cost, "cacheWrite")
    input_tokens = usage.input + usage.cacheRead + usage.cacheWrite
    matched_threshold = -1
    for tier in model.costTiers
        if input_tokens > tier.inputTokensAbove && tier.inputTokensAbove > matched_threshold
            input_rate = tier.input
            output_rate = tier.output
            cache_read_rate = tier.cacheRead
            cache_write_rate = tier.cacheWrite
            matched_threshold = tier.inputTokensAbove
        end
    end
    cost = Dict{String, Float64}(
        "input" => (input_rate / 1000000) * usage.input,
        "output" => (output_rate / 1000000) * usage.output,
        "cacheRead" => (cache_read_rate / 1000000) * usage.cacheRead,
        "cacheWrite" => (cache_write_rate / 1000000) * usage.cacheWrite,
    )
    cost["total"] = cost["input"] + cost["output"] + cost["cacheRead"] + cost["cacheWrite"]
    return cost
end

# Load generated models
include("models_generated.jl")
include("models_custom.jl")
