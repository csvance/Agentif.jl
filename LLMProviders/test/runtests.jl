using Test
using JSON
using JSONSchema
using LLMProviders

const OpenAIResponses = LLMProviders.OpenAIResponses
const OpenAICompletions = LLMProviders.OpenAICompletions
const AnthropicMessages = LLMProviders.AnthropicMessages
const GoogleGenerativeAI = LLMProviders.GoogleGenerativeAI
const GoogleGeminiCli = LLMProviders.GoogleGeminiCli

# Mirrors the field surface of Agentif.Usage (which has no `cost` field);
# calculateCost must not require or mutate one.
struct DummyUsage
    input::Int
    output::Int
    cacheRead::Int
    cacheWrite::Int
end

@testset "OpenAICompletions" begin
    msg = OpenAICompletions.Message(
        ; role = "assistant",
        content = "hello",
        extra = Dict("custom_key" => "custom_value"),
    )
    lowered = JSON.lower(msg)
    @test lowered["role"] == "assistant"
    @test lowered["content"] == "hello"
    @test lowered["custom_key"] == "custom_value"

    tool_delta = OpenAICompletions.StreamToolCallDelta(
        ; index = 0,
        id = "call-1",
        var"function" = OpenAICompletions.StreamToolCallFunctionDelta(; name = "read", arguments = "{\"path\":\"README.md\"}"),
    )
    chunk = OpenAICompletions.StreamChunk(
        ; choices = [OpenAICompletions.StreamChoice(; delta = OpenAICompletions.StreamDelta(; tool_calls = [tool_delta]), index = 0)],
    )
    parsed = JSON.parse(JSON.json(chunk), OpenAICompletions.StreamChunk)
    @test parsed.choices[1].delta.tool_calls[1].var"function".name == "read"

    req = OpenAICompletions.Request(
        ; model = "openrouter-test",
        messages = [OpenAICompletions.Message(; role = "user", content = "hello")],
        stream = true,
        provider = Dict("zdr" => true, "data_collection" => "deny"),
        reasoning = Dict("exclude" => true),
    )
    req_json = JSON.parse(JSON.json(req))
    @test req_json["provider"]["zdr"] == true
    @test req_json["provider"]["data_collection"] == "deny"
    @test req_json["reasoning"]["exclude"] == true

    usage_chunk = JSON.parse(
        """
        {
          "choices": [{"delta": {}, "index": 0}],
          "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 4,
            "total_tokens": 14,
            "prompt_tokens_details": {"cached_tokens": 3},
            "completion_tokens_details": {"reasoning_tokens": 2}
          }
        }
        """,
        OpenAICompletions.StreamChunk,
    )
    @test usage_chunk.usage !== nothing
    @test usage_chunk.usage.prompt_tokens_details.cached_tokens == 3
    @test usage_chunk.usage.completion_tokens_details.reasoning_tokens == 2
end

@testset "OpenAIResponses" begin
    content_json = Vector{UInt8}(codeunits("{\"type\":\"input_text\",\"text\":\"hello\"}"))
    content = JSON.parse(content_json, OpenAIResponses.Content)
    @test content isa OpenAIResponses.InputTextContent
    @test content.text == "hello"

    output = JSON.parse("{\"type\":\"function_call\",\"arguments\":\"{}\",\"call_id\":\"call-1\",\"name\":\"echo\"}", OpenAIResponses.Output)
    @test output isa OpenAIResponses.FunctionToolCall
    @test output.name == "echo"

    event = JSON.parse("{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}", OpenAIResponses.StreamEvent)
    @test event isa OpenAIResponses.StreamOutputTextDeltaEvent
    @test event.delta == "hi"

    unknown_content = JSON.parse("{\"type\":\"output_audio\",\"audio\":\"...\"}", OpenAIResponses.Content)
    @test unknown_content isa OpenAIResponses.UnknownContent

    unknown_output = JSON.parse("{\"type\":\"new_output_type\",\"foo\":\"bar\"}", OpenAIResponses.Output)
    @test unknown_output isa OpenAIResponses.UnknownOutput

    unknown_event = JSON.parse("{\"type\":\"response.unrecognized\",\"foo\":123}", OpenAIResponses.StreamEvent)
    @test unknown_event isa OpenAIResponses.UnknownStreamEvent

    params_schema = OpenAIResponses.schema(
        @NamedTuple{required::String, optional::Union{Nothing,String}},
    )
    params_schema_data = JSONSchema.spec(params_schema)
    required_fields =
        haskey(params_schema_data, "required") ?
        Set(String.(params_schema_data["required"])) :
        Set{String}()
    @test "required" in required_fields
    @test !("optional" in required_fields)
end

@testset "AnthropicMessages" begin
    event = JSON.parse(
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}",
        AnthropicMessages.StreamEvent,
    )
    @test event isa AnthropicMessages.StreamContentBlockDeltaEvent
    @test event.delta isa AnthropicMessages.TextDelta
    @test event.delta.text == "hello"

    msg = JSON.parse("{\"role\":\"user\",\"content\":\"hi\"}", AnthropicMessages.Message)
    @test msg.content == "hi"

    # redacted_thinking parses as a first-class block
    redacted_event = JSON.parse(
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"}}",
        AnthropicMessages.StreamEvent,
    )
    @test redacted_event isa AnthropicMessages.StreamContentBlockStartEvent
    @test redacted_event.content_block isa AnthropicMessages.RedactedThinkingBlock
    @test redacted_event.content_block.data == "EmwKAhgB"

    # redacted_thinking serializes back to the wire shape for replay
    lowered = JSON.parse(JSON.json(AnthropicMessages.RedactedThinkingBlock(; data = "opaque")))
    @test lowered["type"] == "redacted_thinking"
    @test lowered["data"] == "opaque"

    # unknown content block types parse to the catch-all instead of throwing
    unknown_block_event = JSON.parse(
        "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_1\",\"name\":\"web_search\",\"input\":{}}}",
        AnthropicMessages.StreamEvent,
    )
    @test unknown_block_event isa AnthropicMessages.StreamContentBlockStartEvent
    @test unknown_block_event.content_block isa AnthropicMessages.UnknownContentBlock
    @test unknown_block_event.content_block.type == "server_tool_use"

    # unknown delta types parse to the catch-all instead of throwing
    unknown_delta_event = JSON.parse(
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"web_search_result_location\"}}}",
        AnthropicMessages.StreamEvent,
    )
    @test unknown_delta_event isa AnthropicMessages.StreamContentBlockDeltaEvent
    @test unknown_delta_event.delta isa AnthropicMessages.UnknownContentBlockDelta
    @test unknown_delta_event.delta.type == "citations_delta"

    # non-streaming Response tolerates unknown and redacted blocks
    response = JSON.parse(
        """
        {
          "id": "msg_1",
          "model": "claude-test",
          "role": "assistant",
          "stop_reason": "end_turn",
          "content": [
            {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "x"}},
            {"type": "redacted_thinking", "data": "opaque"},
            {"type": "text", "text": "done"}
          ],
          "usage": {"input_tokens": 3, "output_tokens": 5}
        }
        """,
        AnthropicMessages.Response,
    )
    @test response.content[1] isa AnthropicMessages.UnknownContentBlock
    @test response.content[2] isa AnthropicMessages.RedactedThinkingBlock
    @test response.content[2].data == "opaque"
    @test response.content[3] isa AnthropicMessages.TextBlock
    @test response.content[3].text == "done"

    # adaptive thinking + effort serialize to the documented wire shapes
    adaptive = AnthropicMessages.Request(
        ; model = "claude-opus-5",
        messages = AnthropicMessages.Message[AnthropicMessages.Message(; role = "user", content = "hi")],
        max_tokens = 4096,
        thinking = AnthropicMessages.ThinkingConfig(; type = "adaptive", display = "summarized"),
        output_config = AnthropicMessages.OutputConfig(; effort = "xhigh"),
        metadata = Dict("user_id" => "u-1"),
    )
    adaptive_body = JSON.parse(JSON.json(adaptive))
    @test adaptive_body["thinking"]["type"] == "adaptive"
    @test adaptive_body["thinking"]["display"] == "summarized"
    @test !haskey(adaptive_body["thinking"], "budget_tokens")
    @test adaptive_body["output_config"]["effort"] == "xhigh"
    @test adaptive_body["metadata"]["user_id"] == "u-1"
    @test !haskey(adaptive_body, "temperature")

    sampled = AnthropicMessages.Request(
        ; model = "claude-3-5-haiku-latest",
        messages = AnthropicMessages.Message[],
        max_tokens = 1024,
        top_k = 40,
    )
    @test JSON.parse(JSON.json(sampled))["top_k"] == 40

    # budget-based thinking keeps budget_tokens strictly below max_tokens
    budgeted = AnthropicMessages.Request(
        ; model = "claude-haiku-4-5",
        messages = AnthropicMessages.Message[],
        max_tokens = 12288,
        thinking = AnthropicMessages.ThinkingConfig(; type = "enabled", budget_tokens = 8192),
    )
    budget_body = JSON.parse(JSON.json(budgeted))
    @test budget_body["thinking"]["type"] == "enabled"
    @test !haskey(budget_body["thinking"], "display")
    @test budget_body["thinking"]["budget_tokens"] == 8192
    @test budget_body["thinking"]["budget_tokens"] < budget_body["max_tokens"]
    @test !haskey(budget_body, "output_config")

    # cache_control breakpoints ride on system blocks and on user content blocks
    cached = AnthropicMessages.Request(
        ; model = "claude-opus-5",
        messages = AnthropicMessages.Message[
            AnthropicMessages.Message(
                ; role = "user",
                content = AnthropicMessages.ContentBlock[
                    AnthropicMessages.ToolResultBlock(
                        ; tool_use_id = "t1",
                        content = "ok",
                        cache_control = AnthropicMessages.CacheControl(; type = "ephemeral"),
                    ),
                ],
            ),
        ],
        max_tokens = 1024,
        system = AnthropicMessages.TextBlock[
            AnthropicMessages.TextBlock(
                ; text = "sys",
                cache_control = AnthropicMessages.CacheControl(; type = "ephemeral", ttl = "1h"),
            ),
        ],
    )
    cached_body = JSON.parse(JSON.json(cached))
    @test cached_body["system"][1]["cache_control"]["type"] == "ephemeral"
    @test cached_body["system"][1]["cache_control"]["ttl"] == "1h"
    tool_result_body = cached_body["messages"][1]["content"][1]
    @test tool_result_body["cache_control"]["type"] == "ephemeral"
    # the default 5m ephemeral cache omits the ttl field entirely
    @test !haskey(tool_result_body["cache_control"], "ttl")

    image_block = AnthropicMessages.ImageBlock(; source = AnthropicMessages.ImageSource(; media_type = "image/png", data = "AAA"))
    @test JSON.parse(JSON.json(image_block)) |> b -> !haskey(b, "cache_control")
    image_block.cache_control = AnthropicMessages.CacheControl(; type = "ephemeral")
    @test JSON.parse(JSON.json(image_block))["cache_control"]["type"] == "ephemeral"
end

@testset "GoogleGenerativeAI" begin
    schema = Dict("\$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => Any["string", "null"])
    sanitized = GoogleGenerativeAI.sanitize_schema(schema)
    @test !haskey(sanitized, "\$schema")
    @test sanitized["type"] == "string"
    @test sanitized["nullable"] == true

    anyof_schema = Dict("anyOf" => Any[Dict("type" => "null"), Dict("type" => "integer")])
    sanitized_anyof = GoogleGenerativeAI.sanitize_schema(anyof_schema)
    @test sanitized_anyof["type"] == "integer"
    @test sanitized_anyof["nullable"] == true
end

@testset "GoogleGeminiCli" begin
    model = LLMProviders.Model(
        ; id = "gemini-test",
        name = "Gemini Test",
        api = "google-gemini-cli",
        provider = "google",
        baseUrl = GoogleGeminiCli.DEFAULT_ENDPOINT,
        reasoning = true,
        input = ["text"],
        cost = Dict("input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0),
        contextWindow = 1048576,
        maxTokens = 8192,
    )

    contents = [GoogleGeminiCli.Content(; role = "user", parts = [GoogleGeminiCli.Part(; text = "Hello")])]
    req = GoogleGeminiCli.build_request(
        model,
        contents,
        "project-123";
        toolChoice = "none",
        maxTokens = 256,
        temperature = 0.2,
        thinking = (; enabled = true, level = "high"),
    )
    @test req.project == "project-123"
    @test req.request.toolConfig.functionCallingConfig.mode == "NONE"
    @test req.request.generationConfig.maxOutputTokens == 256
    @test req.request.generationConfig.thinkingConfig.includeThoughts == true
    @test req.request.generationConfig.thinkingConfig.thinkingLevel == "high"
    @test startswith(req.requestId, "agentif-")

    @test GoogleGeminiCli.map_tool_choice("auto") == "AUTO"
    @test GoogleGeminiCli.map_tool_choice("none") == "NONE"
    @test GoogleGeminiCli.map_tool_choice("any") == "ANY"
    @test GoogleGeminiCli.map_tool_choice("unknown") == "AUTO"

    token, project = GoogleGeminiCli.parse_oauth_credentials("{\"token\":\"abc\",\"projectId\":\"proj\"}")
    @test token == "abc"
    @test project == "proj"
end

@testset "Model registry helpers" begin
    provider = "unit-provider-$(rand(1:10^9))"
    model = LLMProviders.Model(
        ; id = "unit-model",
        name = "Unit Model",
        api = "openai-completions",
        provider = provider,
        baseUrl = "https://example.com/v1",
        reasoning = false,
        input = ["text"],
        cost = Dict("input" => 1.0, "output" => 2.0),  # intentionally partial to verify default zero handling
        contextWindow = 4096,
        maxTokens = 1024,
    )
    LLMProviders.registerModel!(model)
    fetched = LLMProviders.getModel(provider, "unit-model")
    @test fetched !== nothing
    @test fetched.id == "unit-model"
    @test provider in LLMProviders.getProviders()
    @test any(m -> m.id == "unit-model", LLMProviders.getModels(provider))

    usage = DummyUsage(1000, 2000, 3000, 4000)
    cost = LLMProviders.calculateCost(model, usage)
    @test cost["input"] == 0.001
    @test cost["output"] == 0.004
    @test cost["cacheRead"] == 0.0
    @test cost["cacheWrite"] == 0.0
    @test cost["total"] == 0.005

    tiered = LLMProviders.Model(;
        id = "tiered",
        name = "Tiered",
        api = "openai-responses",
        provider,
        baseUrl = "https://example.com/v1",
        reasoning = true,
        input = ["text"],
        cost = Dict("input" => 1.0, "output" => 2.0, "cacheRead" => 0.1, "cacheWrite" => 1.25),
        contextWindow = 1000,
        maxTokens = 100,
        costTiers = [
            LLMProviders.ModelCostTier(;
                inputTokensAbove = 100,
                input = 10.0,
                output = 20.0,
                cacheRead = 1.0,
                cacheWrite = 12.5,
            ),
            LLMProviders.ModelCostTier(;
                inputTokensAbove = 200,
                input = 100.0,
                output = 200.0,
                cacheRead = 10.0,
                cacheWrite = 125.0,
            ),
        ],
    )
    # The threshold is strict and includes input, cache-read, and cache-write tokens.
    @test LLMProviders.calculateCost(tiered, DummyUsage(50, 10, 50, 0))["input"] ≈ 0.00005
    @test LLMProviders.calculateCost(tiered, DummyUsage(50, 10, 50, 1))["input"] ≈ 0.0005
    @test LLMProviders.calculateCost(tiered, DummyUsage(100, 10, 100, 1))["input"] ≈ 0.01
end

@testset "Generated model registry" begin
    # Roster shipped by models_generated.json plus models_custom.jl. Keep this
    # explicit so providers registered by earlier testsets do not enter the sweep.
    registry_providers = [
        "amazon-bedrock", "ant-ling", "anthropic", "azure-openai-responses",
        "cerebras", "cloudflare-ai-gateway", "cloudflare-workers-ai", "deepseek",
        "fireworks", "github-copilot", "google", "google-gemini-cli",
        "google-vertex", "groq", "huggingface", "kimi-coding", "minimax",
        "minimax-cn", "mistral", "moonshotai", "moonshotai-cn", "nvidia",
        "openai", "openai-codex", "opencode", "opencode-go", "openrouter",
        "qwen-token-plan", "qwen-token-plan-cn", "together",
        "vercel-ai-gateway", "xai", "xiaomi", "xiaomi-token-plan-ams",
        "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp", "zai", "zai-coding-cn",
    ]
    @test issubset(registry_providers, LLMProviders.getProviders())
    all_models = [m for p in registry_providers for m in LLMProviders.getModels(p)]
    @test length(all_models) >= 1168

    # Current upstream examples, including the active Sonnet 5 introductory rate.
    for (provider, id, input, output) in [
            ("anthropic", "claude-sonnet-5", 2.0, 10.0),
            ("anthropic", "claude-opus-5", 5.0, 25.0),
            ("anthropic", "claude-fable-5", 10.0, 50.0),
            ("openai", "gpt-5.4", 2.5, 15.0),
            ("google", "gemini-3.1-pro-preview", 2.0, 12.0),
            ("zai", "glm-5.2", 0.0, 0.0),
        ]
        model = LLMProviders.getModel(provider, id)
        @test model !== nothing
        if model !== nothing
            @test model.id == id
            @test model.provider == provider
            @test model.cost["input"] == input
            @test model.cost["output"] == output
            @test model.contextWindow > 0
            @test model.maxTokens > 0
        end
    end

    for provider in [
            "ant-ling", "cloudflare-ai-gateway", "cloudflare-workers-ai",
            "deepseek", "fireworks", "moonshotai", "nvidia", "qwen-token-plan",
            "together", "xiaomi",
        ]
        @test !isempty(LLMProviders.getModels(provider))
    end

    # OpenRouter has two documented dynamic-pricing sentinels.
    negative_cost_sentinels = Set([
        ("openrouter", "openrouter/auto"),
        ("openrouter", "openrouter/auto-beta"),
    ])
    for model in all_models
        key = (model.provider, model.id)
        if key in negative_cost_sentinels
            @test model.cost["input"] == -1.0e6
        else
            @test all(>=(0.0), values(model.cost))
        end
        @test model.contextWindow > 0
        @test model.maxTokens > 0
        @test !isempty(model.id)
        @test !isempty(model.api)
        @test !isempty(model.input)
        @test all(tier -> tier.inputTokensAbove >= 0, model.costTiers)
        @test all(
            tier -> all(>=(0.0), (tier.input, tier.output, tier.cacheRead, tier.cacheWrite)),
            model.costTiers,
        )
    end
    @test all(m -> issetequal(keys(m.cost), ["input", "output", "cacheRead", "cacheWrite"]), all_models)

    # Tier and thinking metadata survive the JSON loader.
    sol = LLMProviders.getModel("openai", "gpt-5.6-sol")
    @test sol !== nothing
    @test sol !== nothing && length(sol.costTiers) == 1
    @test sol !== nothing && sol.costTiers[1].inputTokensAbove == 272000
    @test sol !== nothing && sol.costTiers[1].output == 45.0
    @test sol !== nothing && sol.thinkingLevelMap["xhigh"] == "xhigh"

    # models_custom.jl remains an overlay.
    spark = LLMProviders.getModel("openai-codex", "gpt-5.3-codex-spark")
    @test spark !== nothing && spark.maxTokens == 32000
    for id in ["gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4"]
        model = LLMProviders.getModel("openai-codex", id)
        @test model !== nothing
        @test model !== nothing && all(==(0.0), values(model.cost))
    end
    @test LLMProviders.getModel("minimax", "MiniMax-M2.7") !== nothing

    for model in LLMProviders.getModels("google-gemini-cli")
        @test model.api == "google-gemini-cli"
        @test model.baseUrl == "https://cloudcode-pa.googleapis.com"
        @test all(==(0.0), values(model.cost))
    end
end

@testset "Generated frontier Anthropic models" begin
    expected = Dict(
        "claude-fable-5"  => (10.0, 50.0),
        "claude-opus-5"   => (5.0, 25.0),
        "claude-sonnet-5" => (2.0, 10.0),
        "claude-opus-4-8" => (5.0, 25.0),
        "claude-opus-4-7" => (5.0, 25.0),
    )
    for (id, (input_cost, output_cost)) in expected
        model = LLMProviders.getModel("anthropic", id)
        @test model !== nothing
        model === nothing && continue
        @test model.api == "anthropic-messages"
        @test model.provider == "anthropic"
        @test model.cost["input"] == input_cost
        @test model.cost["output"] == output_cost
        @test model.cost["cacheRead"] == input_cost * 0.1
        @test model.cost["cacheWrite"] == input_cost * 1.25
        @test model.contextWindow == 1000000
        @test model.maxTokens == 128000
        @test model.reasoning
        @test model.thinkingLevelMap !== nothing
    end

    haiku = LLMProviders.getModel("anthropic", "claude-haiku-4-5")
    @test haiku !== nothing
    @test haiku.cost["input"] == 1
    @test haiku.contextWindow == 200000
end

include("generator_test.jl")
