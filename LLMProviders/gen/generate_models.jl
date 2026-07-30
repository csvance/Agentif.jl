#!/usr/bin/env julia
#
# generate_models.jl -- regenerate LLMProviders/src/models_generated.jl from
# pi-mono's generated JSON model catalog.
#
# Usage:
#     julia LLMProviders/gen/generate_models.jl [SOURCE] [OUTPUT_JL]
#
# Defaults:
#     SOURCE     $PI_MONO_MODELS_JSON, else
#                $PI_MONO/.artifacts/model-catalog/models.json,
#                with legacy monolithic models.generated.ts support
#     OUTPUT_JL  <this file>/../../src/models_generated.jl
#
# The script is dependency-free (Base only). pi-mono owns network discovery and
# emits the JSON snapshot; this script performs a deterministic conversion of
# that snapshot. See gen/README.md.

const DEFAULT_JSON_RELPATH = joinpath(".artifacts", "model-catalog", "models.json")
const LEGACY_TS_RELPATH = joinpath("packages", "ai", "src", "models.generated.ts")

# ---------------------------------------------------------------------------
# Value model
#
# Parsed catalog values are kept in a tiny tagged representation so that numbers can
# survive as their *verbatim source token*. Reparsing them as Float64 and
# re-printing would silently rewrite upstream values (e.g. 0.19999999999999998
# vs 0.2); the existing checked-in file preserves the raw tokens, and so do we.
# ---------------------------------------------------------------------------

struct TSNum          # verbatim numeric token, e.g. "0.19999999999999998" or "4"
    token::String
end

struct TSStr
    value::String
end

struct TSBool
    value::Bool
end

const TSArray = Vector{Any}
const TSObject = Vector{Pair{String, Any}}   # ordered, upstream key order preserved

# ---------------------------------------------------------------------------
# Scalar / inline-literal parsing
# ---------------------------------------------------------------------------

"""
    parse_js_string(s, i) -> (String, nextindex)

Parse a double-quoted JS/JSON string literal starting at `s[i] == '"'`.
Handles the standard escape set including `\\uXXXX` (with surrogate pairs).
"""
function parse_js_string(s::AbstractString, i::Int)
    @assert s[i] == '"' "expected '\"' at index $i in: $(first(s, 120))"
    io = IOBuffer()
    i = nextind(s, i)
    while i <= lastindex(s)
        c = s[i]
        if c == '"'
            return String(take!(io)), nextind(s, i)
        elseif c == '\\'
            i = nextind(s, i)
            i <= lastindex(s) || error("unterminated escape in string literal")
            e = s[i]
            if e == 'n'
                print(io, '\n')
            elseif e == 't'
                print(io, '\t')
            elseif e == 'r'
                print(io, '\r')
            elseif e == 'b'
                print(io, '\b')
            elseif e == 'f'
                print(io, '\f')
            elseif e == '/'
                print(io, '/')
            elseif e == '\\'
                print(io, '\\')
            elseif e == '"'
                print(io, '"')
            elseif e == 'u'
                hex = s[(i + 1):(i + 4)]
                cp = parse(UInt32, hex; base = 16)
                i += 4
                if 0xD800 <= cp <= 0xDBFF && i + 6 <= lastindex(s) && s[i + 1] == '\\' && s[i + 2] == 'u'
                    lo = parse(UInt32, s[(i + 3):(i + 6)]; base = 16)
                    if 0xDC00 <= lo <= 0xDFFF
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        i += 6
                    end
                end
                print(io, Char(cp))
            else
                error("unsupported escape '\\$e' in string literal")
            end
            i = nextind(s, i)
        else
            print(io, c)
            i = nextind(s, i)
        end
    end
    return error("unterminated string literal")
end

skipws(s::AbstractString, i::Int) = (while i <= lastindex(s) && isspace(s[i]); i = nextind(s, i); end; i)

"""
    parse_value(s, i) -> (value, nextindex)

Parse one inline TS/JSON value (string, number, bool, null, array, object).
Only used for values that upstream emits on a single line: `input`, `compat`,
`headers`, and every scalar. Multi-line blocks (`cost`) are handled by the
line-oriented reader below.
"""
function parse_value(s::AbstractString, i::Int)
    i = skipws(s, i)
    i <= lastindex(s) || error("unexpected end of value")
    c = s[i]
    if c == '"'
        v, i = parse_js_string(s, i)
        return TSStr(v), i
    elseif c == '['
        arr = TSArray()
        i = skipws(s, nextind(s, i))
        if i <= lastindex(s) && s[i] == ']'
            return arr, nextind(s, i)
        end
        while true
            v, i = parse_value(s, i)
            push!(arr, v)
            i = skipws(s, i)
            i <= lastindex(s) || error("unterminated array")
            if s[i] == ','
                i = nextind(s, i)
            elseif s[i] == ']'
                return arr, nextind(s, i)
            else
                error("unexpected char '$(s[i])' in array")
            end
        end
    elseif c == '{'
        obj = TSObject()
        i = skipws(s, nextind(s, i))
        if i <= lastindex(s) && s[i] == '}'
            return obj, nextind(s, i)
        end
        while true
            i = skipws(s, i)
            local key::String
            if s[i] == '"'
                key, i = parse_js_string(s, i)
            else  # bare identifier key
                j = i
                while j <= lastindex(s) && (isletter(s[j]) || isdigit(s[j]) || s[j] in ('_', '$'))
                    j = nextind(s, j)
                end
                j == i && error("expected an object key")
                key = s[i:prevind(s, j)]
                i = j
            end
            any(p -> first(p) == key, obj) && error("duplicate object key '$key'")
            i = skipws(s, i)
            s[i] == ':' || error("expected ':' after object key '$key'")
            v, i = parse_value(s, nextind(s, i))
            push!(obj, key => v)
            i = skipws(s, i)
            i <= lastindex(s) || error("unterminated object")
            if s[i] == ','
                i = nextind(s, i)
                i = skipws(s, i)
                s[i] == '}' && return obj, nextind(s, i)   # tolerate trailing comma
            elseif s[i] == '}'
                return obj, nextind(s, i)
            else
                error("unexpected char '$(s[i])' in object")
            end
        end
    elseif startswith(SubString(s, i), "true")
        return TSBool(true), i + 4
    elseif startswith(SubString(s, i), "false")
        return TSBool(false), i + 5
    elseif startswith(SubString(s, i), "null")
        return nothing, i + 4
    elseif c == '-' || isdigit(c)
        j = i
        while j <= lastindex(s) && (isdigit(s[j]) || s[j] in ('-', '+', '.', 'e', 'E'))
            j = nextind(s, j)
        end
        tok = s[i:prevind(s, j)]
        # sanity: must reparse as a number
        parse(Float64, tok)
        return TSNum(tok), j
    end
    return error("unrecognized value starting with '$c'")
end

function parse_complete_value(s::AbstractString; context::AbstractString)
    isempty(s) && error("$context: empty input")
    value, i = parse_value(s, firstindex(s))
    i = skipws(s, i)
    i > lastindex(s) || error("$context: unexpected trailing content: $(first(SubString(s, i), 80))")
    return value
end

function parse_line_value(s::AbstractString; context::AbstractString)
    value, i = parse_value(s, firstindex(s))
    i = skipws(s, i)
    if i <= lastindex(s) && s[i] == ','
        i = skipws(s, nextind(s, i))
    end
    i > lastindex(s) || error("$context: unexpected trailing content: $(first(SubString(s, i), 80))")
    return value
end

# ---------------------------------------------------------------------------
# Line-oriented TS reader
# ---------------------------------------------------------------------------

struct ParsedModel
    provider::String
    id::String
    fields::TSObject
end

"""
    parse_models_ts(path) -> Vector{ParsedModel}

Read `models.generated.ts` and return every model literal it declares.

Structure relied upon (upstream is machine-generated, so indentation is exact):

    export const MODELS = {
    \\t"<provider>": {
    \\t\\t"<model-id>": {
    \\t\\t\\t<key>: <inline value>,
    \\t\\t\\tcost: {
    \\t\\t\\t\\t<key>: <number>,
    \\t\\t\\t},
    \\t\\t} satisfies Model<"...">,
    \\t},
    } as const;

Anything unexpected raises rather than being silently skipped, so upstream
shape drift surfaces as a generator failure instead of a truncated registry.
"""
function parse_models_ts(path::AbstractString)
    lines = readlines(path)
    models = ParsedModel[]

    start = findfirst(l -> startswith(l, "export const MODELS"), lines)
    start === nothing && error("could not find `export const MODELS` in $path")
    any(occursin("readonly "), lines[start:min(length(lines), start + 5)]) &&
        error(
        "$path uses pi-mono's split JSON catalog format. " *
            "Run `npm --prefix packages/ai run generate-model-catalog` in pi-mono, " *
            "then pass `.artifacts/model-catalog/models.json` to this script."
    )

    provider = ""
    id = ""
    fields = TSObject()
    nested_key = ""
    nested = TSObject()
    # depth: 1 = inside MODELS, 2 = inside a provider, 3 = inside a model, 4 = inside a nested block
    depth = 1

    terminated = false
    for lineno in (start + 1):length(lines)
        raw = lines[lineno]
        line = rstrip(raw)
        isempty(strip(line)) && continue
        if line == "} as const;"
            terminated = true
            break
        end

        indent = something(findfirst(c -> c != '\t', line), length(line) + 1) - 1
        body = lstrip(line, '\t')

        if depth == 1
            if indent == 1 && endswith(body, ": {")
                provider, _ = parse_js_string(body, 1)
                depth = 2
            else
                error("$path:$lineno: expected a provider key, got: $line")
            end
        elseif depth == 2
            if indent == 2 && endswith(body, ": {")
                id, _ = parse_js_string(body, 1)
                fields = TSObject()
                depth = 3
            elseif indent == 1 && (body == "}," || body == "}")
                depth = 1
            else
                error("$path:$lineno: expected a model key or provider close, got: $line")
            end
        elseif depth == 3
            if indent == 2 && (startswith(body, "} satisfies") || body == "}," || body == "}")
                push!(models, ParsedModel(provider, id, fields))
                depth = 2
            elseif indent == 3
                colon = findfirst(==(':'), body)
                colon === nothing && error("$path:$lineno: missing ':' in field line: $line")
                key = strip(body[1:(colon - 1)], ['"', ' '])
                rest = strip(body[(colon + 1):end])
                if rest == "{"
                    nested_key = key
                    nested = TSObject()
                    depth = 4
                else
                    v = parse_line_value(rest; context = "$path:$lineno")
                    push!(fields, key => v)
                end
            else
                error("$path:$lineno: unexpected line inside model \"$id\": $line")
            end
        else # depth == 4
            if indent == 3 && (body == "}," || body == "}")
                push!(fields, nested_key => nested)
                depth = 3
            elseif indent == 4
                colon = findfirst(==(':'), body)
                colon === nothing && error("$path:$lineno: missing ':' in nested field line: $line")
                key = strip(body[1:(colon - 1)], ['"', ' '])
                v = parse_line_value(strip(body[(colon + 1):end]); context = "$path:$lineno")
                push!(nested, key => v)
            else
                error("$path:$lineno: unexpected line inside \"$id\".$nested_key: $line")
            end
        end
    end

    terminated || error("$path: missing closing `} as const;`")
    depth == 1 || error("$path: unbalanced literal (ended at depth $depth)")
    isempty(models) && error("$path: parsed zero models")
    return models
end

"""
    parse_models_json(path) -> Vector{ParsedModel}

Read the JSON catalog emitted by pi-mono's `generate-model-catalog` task.
The shape is `{provider: {model_id: model}}`. Numeric tokens stay verbatim.
"""
function parse_models_json(path::AbstractString)
    root = parse_complete_value(read(path, String); context = path)
    root isa TSObject || error("$path: expected a top-level provider object")
    models = ParsedModel[]
    for (provider, provider_models) in root
        isempty(provider) && error("$path: provider name cannot be empty")
        provider_models isa TSObject ||
            error("$path: provider \"$provider\" must map to an object")
        for (id, fields) in provider_models
            isempty(id) && error("$path: model id cannot be empty in provider \"$provider\"")
            fields isa TSObject ||
                error("$path: model \"$provider/$id\" must map to an object")
            push!(models, ParsedModel(provider, id, fields))
        end
    end
    isempty(models) && error("$path: parsed zero models")
    return models
end

function parse_models(path::AbstractString)
    return endswith(lowercase(path), ".json") ? parse_models_json(path) : parse_models_ts(path)
end

# ---------------------------------------------------------------------------
# Julia emission
# ---------------------------------------------------------------------------

function jl_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '$'
            print(io, "\\\$")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif UInt32(c) < 0x20
            print(io, "\\u", uppercase(string(UInt32(c); base = 16, pad = 4)))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

jl_value(v::TSStr) = jl_string(v.value)
jl_value(v::TSNum) = v.token
jl_value(v::TSBool) = v.value ? "true" : "false"
jl_value(::Nothing) = "nothing"
jl_value(v::TSArray) = "[" * join(jl_value.(v), ", ") * "]"
jl_value(v::TSObject) = "Dict(" * join(["$(jl_string(k)) => $(jl_value(x))" for (k, x) in v], ", ") * ")"

function getfieldval(fields::TSObject, key::AbstractString)
    idx = findfirst(p -> first(p) == key, fields)
    return idx === nothing ? nothing : last(fields[idx])
end

function require_field(m::ParsedModel, key::AbstractString)
    v = getfieldval(m.fields, key)
    v === nothing && error("model $(m.provider)/$(m.id) is missing required field `$key`")
    return v
end

const KNOWN_FIELDS = Set([
    "id", "name", "api", "provider", "baseUrl", "reasoning",
    "input", "cost", "contextWindow", "maxTokens", "headers", "compat",
    "thinkingLevelMap",
])
const COST_RATE_KEYS = ["input", "output", "cacheRead", "cacheWrite"]
const COST_TIER_KEYS = ["inputTokensAbove", COST_RATE_KEYS...]

function require_object_field(object::TSObject, key::AbstractString, context::AbstractString)
    value = getfieldval(object, key)
    value === nothing && error("$context is missing required field `$key`")
    return value
end

function validate_number(value, context::AbstractString)
    value isa TSNum || error("$context must be numeric")
    return value
end

function validate_cost_tiers(value, context::AbstractString)
    value === nothing && return nothing
    value isa TSArray || error("$context must be an array")
    for (index, tier) in enumerate(value)
        tier_context = "$context[$index]"
        tier isa TSObject || error("$tier_context must be an object")
        keys = first.(tier)
        allunique(keys) || error("$tier_context has duplicate keys")
        issetequal(keys, COST_TIER_KEYS) ||
            error("$tier_context has unexpected keys $keys")
        threshold = validate_number(
            require_object_field(tier, "inputTokensAbove", tier_context),
            "$tier_context.inputTokensAbove",
        )
        occursin(r"^\d+$", threshold.token) ||
            error("$tier_context.inputTokensAbove must be a non-negative integer")
        for key in COST_RATE_KEYS
            validate_number(
                require_object_field(tier, key, tier_context),
                "$tier_context.$key",
            )
        end
    end
    return nothing
end

function validate_string_field(m::ParsedModel, key::AbstractString)
    value = require_field(m, key)
    value isa TSStr || error("model $(m.provider)/$(m.id): `$key` must be a string")
    return value
end

function validate_positive_integer_field(m::ParsedModel, key::AbstractString)
    value = require_field(m, key)
    value isa TSNum || error("model $(m.provider)/$(m.id): `$key` must be numeric")
    occursin(r"^\d+$", value.token) ||
        error("model $(m.provider)/$(m.id): `$key` must be a positive integer")
    parse(Int, value.token) > 0 ||
        error("model $(m.provider)/$(m.id): `$key` must be positive")
    return value
end

function validate_model(m::ParsedModel)
    # Fail loud on upstream schema growth rather than silently dropping a field
    # that `Model` might need to carry.
    field_keys = first.(m.fields)
    allunique(field_keys) ||
        error("model $(m.provider)/$(m.id): duplicate model fields")
    for (k, _) in m.fields
        k in KNOWN_FIELDS ||
            error("model $(m.provider)/$(m.id): unknown upstream field `$k` -- update KNOWN_FIELDS/validate_model")
    end
    idfield = validate_string_field(m, "id")
    idfield.value == m.id ||
        error("model $(m.provider)/$(m.id): `id` field does not match its object key")
    providerfield = validate_string_field(m, "provider")
    providerfield.value == m.provider ||
        error("model $(m.provider)/$(m.id): `provider` field does not match its provider key")
    for key in ("name", "api", "baseUrl")
        validate_string_field(m, key)
    end
    require_field(m, "reasoning") isa TSBool ||
        error("model $(m.provider)/$(m.id): `reasoning` must be boolean")
    input = require_field(m, "input")
    input isa TSArray && !isempty(input) && all(x -> x isa TSStr, input) ||
        error("model $(m.provider)/$(m.id): `input` must be a non-empty string array")
    validate_positive_integer_field(m, "contextWindow")
    validate_positive_integer_field(m, "maxTokens")

    cost = require_field(m, "cost")
    cost isa TSObject || error("model $(m.provider)/$(m.id): `cost` is not an object")
    cost_keys = first.(cost)
    allunique(cost_keys) ||
        error("model $(m.provider)/$(m.id): duplicate `cost` keys")
    allowed_cost_keys = [COST_RATE_KEYS..., "tiers"]
    issetequal(intersect(cost_keys, COST_RATE_KEYS), COST_RATE_KEYS) &&
        all(k -> k in allowed_cost_keys, cost_keys) ||
        error("model $(m.provider)/$(m.id): unexpected `cost` keys $cost_keys")
    for key in COST_RATE_KEYS
        validate_number(
            require_object_field(cost, key, "model $(m.provider)/$(m.id).cost"),
            "model $(m.provider)/$(m.id).cost.$key",
        )
    end
    validate_cost_tiers(
        getfieldval(cost, "tiers"),
        "model $(m.provider)/$(m.id).cost.tiers",
    )
    headers = getfieldval(m.fields, "headers")
    headers === nothing || headers isa TSObject ||
        error("model $(m.provider)/$(m.id): `headers` must be an object or null")
    compat = getfieldval(m.fields, "compat")
    compat === nothing || compat isa TSObject ||
        error("model $(m.provider)/$(m.id): `compat` must be an object or null")
    thinking_level_map = getfieldval(m.fields, "thinkingLevelMap")
    thinking_level_map === nothing || thinking_level_map isa TSObject ||
        error("model $(m.provider)/$(m.id): `thinkingLevelMap` must be an object or null")
    return nothing
end

function json_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif UInt32(c) < 0x20
            print(io, "\\u", lowercase(string(UInt32(c); base = 16, pad = 4)))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

json_value(v::TSStr) = json_string(v.value)
json_value(v::TSNum) = v.token
json_value(v::TSBool) = v.value ? "true" : "false"
json_value(::Nothing) = "null"
json_value(v::TSArray) = "[" * join(json_value.(v), ",") * "]"
json_value(v::TSObject) =
    "{" * join(["$(json_string(k)):$(json_value(x))" for (k, x) in v], ",") * "}"

function canonical_catalog(models::Vector{ParsedModel})
    by_provider = Dict{String, Vector{ParsedModel}}()
    for model in models
        validate_model(model)
        push!(get!(() -> ParsedModel[], by_provider, model.provider), model)
    end
    catalog = TSObject()
    for provider in sort!(collect(keys(by_provider)))
        entries = sort!(by_provider[provider]; by = model -> model.id)
        ids = [model.id for model in entries]
        allunique(ids) || error("duplicate model ids within provider \"$provider\"")
        provider_models = TSObject()
        for model in entries
            push!(provider_models, model.id => model.fields)
        end
        push!(catalog, provider => provider_models)
    end
    return catalog
end

function catalog_json(catalog::TSObject)
    io = IOBuffer()
    println(io, "{")
    for (provider_index, (provider, models)) in enumerate(catalog)
        println(io, "  ", json_string(provider), ": {")
        for (model_index, (id, fields)) in enumerate(models)
            suffix = model_index == length(models) ? "" : ","
            println(io, "    ", json_string(id), ": ", json_value(fields), suffix)
        end
        suffix = provider_index == length(catalog) ? "" : ","
        println(io, "  }", suffix)
    end
    println(io, "}")
    return String(take!(io))
end

function git_describe(path::AbstractString)
    dir = isdir(path) ? path : dirname(path)
    try
        out = read(pipeline(`git -C $dir describe --always --dirty`; stderr = devnull), String)
        return strip(out)
    catch
        return "unknown"
    end
end

function loader_source(
        source_label::AbstractString,
        describe::AbstractString,
        date::AbstractString,
        json_filename::AbstractString,
    )
    return """# This file is auto-generated from pi-mono's model catalog
# Do not edit manually -- run `julia LLMProviders/gen/generate_models.jl` to refresh.
#
# Source:    $source_label
# Source rev: $describe
# Generated: $date

const _GENERATED_MODELS_PATH = joinpath(@__DIR__, $(jl_string(json_filename)))
Base.include_dependency(_GENERATED_MODELS_PATH)

function _generated_optional_dict(data::AbstractDict, key::AbstractString)
    value = get(() -> nothing, data, key)
    value === nothing && return nothing
    value isa AbstractDict || error("generated model field `\$key` must be an object")
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
        entries isa AbstractDict || error("generated provider `\$provider` must be an object")
        models = Dict{String, Model}()
        for id in sort!(String[String(key) for key in keys(entries)])
            models[id] = _generated_model(entries[id])
        end
        _model_registry[provider] = models
    end
    return _model_registry
end

_init_model_registry!()
"""
end

"""
    generate(source_path, out_path; source_label, describe, date)

Parse and validate `source_path`, then write a canonical JSON snapshot next to
the compact Julia loader at `out_path`. Providers and model ids are sorted by
codepoint. Numbers remain verbatim source tokens.
"""
function generate(
        source_path::AbstractString,
        out_path::AbstractString;
        source_label::AbstractString = source_path,
        describe::AbstractString = git_describe(source_path),
        date::AbstractString = string(Dates_today()),
    )
    models = parse_models(source_path)
    catalog = canonical_catalog(models)
    loader_path = abspath(out_path)
    endswith(lowercase(loader_path), ".jl") ||
        error("output path must end in .jl: $loader_path")
    json_path = first(splitext(loader_path)) * ".json"
    mkpath(dirname(loader_path))
    write(json_path, catalog_json(catalog))
    write(
        loader_path,
        loader_source(source_label, describe, date, basename(json_path)),
    )
    return (
        providers = length(catalog),
        models = length(models),
        loader_path,
        json_path,
    )
end

# `Dates` is not a dependency of LLMProviders; derive the ISO date from Base.
function Dates_today()
    t = round(Int, time())
    days = t ÷ 86400
    # civil-from-days (Howard Hinnant's algorithm), epoch 1970-01-01
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y += (m <= 2)
    return string(y, "-", lpad(m, 2, '0'), "-", lpad(d, 2, '0'))
end

"""
    tildify(path)

Render an absolute path under `\$HOME` as `~/...` so the generated header does
not bake one developer's home directory into a checked-in file.
"""
function tildify(path::AbstractString)
    home = homedir()
    return startswith(path, home * "/") ? "~" * path[(length(home) + 1):end] : path
end

function default_source_path()
    json_env = get(ENV, "PI_MONO_MODELS_JSON", "")
    isempty(json_env) || return json_env
    legacy_env = get(ENV, "PI_MONO_MODELS_TS", "")
    isempty(legacy_env) || return legacy_env
    root = get(ENV, "PI_MONO", joinpath(homedir(), "pi-mono"))
    json_path = joinpath(root, DEFAULT_JSON_RELPATH)
    isfile(json_path) && return json_path
    legacy_path = joinpath(root, LEGACY_TS_RELPATH)
    if isfile(legacy_path) && occursin("export const MODELS = {", read(legacy_path, String))
        return legacy_path
    end
    return json_path
end

function main(args::Vector{String})
    source_path = (isempty(args) || isempty(args[1])) ? default_source_path() : args[1]
    out_path = length(args) >= 2 ? args[2] :
        normpath(joinpath(@__DIR__, "..", "src", "models_generated.jl"))
    isfile(source_path) || error(
        "source file not found: $source_path\n" *
            "Run `npm --prefix packages/ai run generate-model-catalog` in pi-mono, " *
            "set PI_MONO_MODELS_JSON, or pass models.json as argument 1."
    )

    result = generate(source_path, out_path; source_label = tildify(abspath(source_path)))
    println("wrote $(result.loader_path)")
    println("wrote $(result.json_path)")
    println("  providers: $(result.providers)")
    println("  models:    $(result.models)")
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(copy(ARGS))
