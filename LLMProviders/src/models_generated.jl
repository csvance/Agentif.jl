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

function _generated_cost_tiers(cost::AbstractDict)
    values = get(() -> Any[], cost, "tiers")
    values isa AbstractVector || error("generated model cost tiers must be an array")
    tiers = ModelCostTier[]
    for value in values
        value isa AbstractDict || error("generated model cost tier must be an object")
        push!(
            tiers,
            ModelCostTier(;
                inputTokensAbove = Int(value["inputTokensAbove"]),
                input = Float64(value["input"]),
                output = Float64(value["output"]),
                cacheRead = Float64(value["cacheRead"]),
                cacheWrite = Float64(value["cacheWrite"]),
            ),
        )
    end
    return tiers
end

function _generated_model(data::AbstractDict)
    cost_data = data["cost"]
    cost_data isa AbstractDict || error("generated model cost must be an object")
    cost = Dict{String, Float64}(
        key => Float64(cost_data[key])
        for key in ("input", "output", "cacheRead", "cacheWrite")
    )
    return Model(;
        id = String(data["id"]),
        name = String(data["name"]),
        api = String(data["api"]),
        provider = String(data["provider"]),
        baseUrl = String(data["baseUrl"]),
        reasoning = Bool(data["reasoning"]),
        input = String[String(value) for value in data["input"]],
        cost,
        contextWindow = Int(data["contextWindow"]),
        maxTokens = Int(data["maxTokens"]),
        headers = _generated_headers(data),
        compat = _generated_optional_dict(data, "compat"),
        costTiers = _generated_cost_tiers(cost_data),
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
