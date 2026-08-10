# This file is auto-generated from pi-mono's model catalog
# Do not edit manually -- run `julia LLMProviders/gen/generate_models.jl` to refresh.
#
# Source:    ~/pi-mono/.artifacts/model-catalog/models.json
# Source rev: v0.0.2-5326-g3059b8131
# Generated: 2026-08-10

const _GENERATED_MODELS_PATH = joinpath(@__DIR__, "models_generated.json")
Base.include_dependency(_GENERATED_MODELS_PATH)

function _generated_optional_dict(data::AbstractDict, key::AbstractString)
    value = get(() -> nothing, data, key)
    value === nothing && return nothing
    value isa AbstractDict || error("generated model field `$key` must be an object")
    result = Dict{String, Any}()
    for (k, v) in value
        result[String(k)] = v
    end
    return result
end

function _generated_headers(data::AbstractDict)
    value = get(() -> nothing, data, "headers")
    value === nothing && return nothing
    value isa AbstractDict || error("generated model field `headers` must be an object")
    result = Dict{String, String}()
    for (k, v) in value
        result[String(k)] = String(v)
    end
    return result
end

function _generated_model(data::AbstractDict)
    return Model(;
        id = String(data["id"]),
        name = String(data["name"]),
        api = String(data["api"]),
        provider = String(data["provider"]),
        baseUrl = String(data["baseUrl"]),
        reasoning = Bool(data["reasoning"]),
        input = String[String(value) for value in data["input"]],
        contextWindow = Int(data["contextWindow"]),
        maxTokens = Int(data["maxTokens"]),
        headers = _generated_headers(data),
        compat = _generated_optional_dict(data, "compat"),
        thinkingLevelMap = _generated_optional_dict(data, "thinkingLevelMap"),
    )
end

function _init_model_registry!()
    catalog = JSON.parse(read(_GENERATED_MODELS_PATH, String))
    catalog isa AbstractDict || error("generated model catalog must be an object")
    empty!(_model_registry)
    for provider in sort!(String[String(key) for key in keys(catalog)])
        entries = catalog[provider]
        entries isa AbstractDict || error("generated provider `$provider` must be an object")
        models = Dict{String, Model}()
        for id in sort!(String[String(key) for key in keys(entries)])
            models[id] = _generated_model(entries[id])
        end
        _model_registry[provider] = models
    end
    return _model_registry
end

_init_model_registry!()
