# Model definitions and registry
# Ported from TypeScript models.ts and models.generated.ts

# Model type definitions
@kwarg struct Model
    id::String
    name::String
    api::String  # "openai-responses", "openai-completions", "anthropic-messages", "google-generative-ai"
    provider::String
    baseUrl::String
    reasoning::Bool
    input::Vector{String}  # ["text"], ["text", "image"], etc.
    contextWindow::Int
    maxTokens::Int
    headers::Union{Nothing, Dict{String, String}} = nothing
    compat::Union{Nothing, Dict{String, Any}} = nothing
    kw::Any = (;) # additional keyword arguments that will be passed when api calls are made
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

# Load generated models
include("models_generated.jl")
include("models_custom.jl")
