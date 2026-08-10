module GeneratorTests

using Test

include(joinpath(@__DIR__, "..", "gen", "generate_models.jl"))

const MODEL_A = """
{
  "id": "a",
  "name": "Model A",
  "api": "openai-responses",
  "provider": "a",
  "baseUrl": "https://a.example/v1",
  "reasoning": false,
  "input": ["text"],
  "cost": {
    "input": 0.19999999999999998,
    "output": 2,
    "cacheRead": 0.1,
    "cacheWrite": 1.25
  },
  "contextWindow": 4096,
  "maxTokens": 1024
}
"""

const MODEL_B = """
{
  "id": "b",
  "name": "Model B",
  "api": "anthropic-messages",
  "provider": "z",
  "baseUrl": "https://z.example",
  "reasoning": true,
  "input": ["text", "image"],
  "cost": {
    "input": 1,
    "output": 5,
    "cacheRead": 0.1,
    "cacheWrite": 1.25,
    "tiers": [
      {
        "inputTokensAbove": 200000,
        "input": 2,
        "output": 9,
        "cacheRead": 0.2,
        "cacheWrite": 2.5
      }
    ]
  },
  "contextWindow": 1000000,
  "maxTokens": 128000,
  "compat": {"forceAdaptiveThinking": true},
  "thinkingLevelMap": {"off": null, "xhigh": "xhigh"}
}
"""

@testset "model registry generator" begin
    mktempdir() do dir
        # Deliberately reverse provider order. Canonical output sorts it.
        source = joinpath(dir, "source.json")
        write(source, """{"z":{"b":$MODEL_B},"a":{"a":$MODEL_A}}""")
        loader = joinpath(dir, "models_generated.jl")

        result = generate(
            source,
            loader;
            source_label = "fixture/models.json",
            describe = "fixture-rev",
            date = "2026-07-30",
        )
        @test result.providers == 2
        @test result.models == 2
        @test isfile(result.loader_path)
        @test isfile(result.json_path)

        canonical = read(result.json_path, String)
        generated_loader = read(result.loader_path, String)
        @test startswith(canonical, "{\n  \"a\": {")
        @test occursin("\"input\":0.19999999999999998", canonical)
        @test occursin("\"inputTokensAbove\":200000", canonical)
        @test occursin("Base.include_dependency", generated_loader)

        # Fixed metadata plus fixed input is byte-identical across runs.
        generate(
            source,
            loader;
            source_label = "fixture/models.json",
            describe = "fixture-rev",
            date = "2026-07-30",
        )
        @test read(result.json_path, String) == canonical
        @test read(result.loader_path, String) == generated_loader

        parsed = parse_models_json(result.json_path)
        @test length(parsed) == 2

        mismatch = joinpath(dir, "mismatch.json")
        write(mismatch, """{"a":{"a":$(replace(MODEL_A, "\"provider\": \"a\"" => "\"provider\": \"wrong\""))}}""")
        @test_throws ErrorException generate(mismatch, joinpath(dir, "mismatch.jl"))

        duplicate = joinpath(dir, "duplicate.json")
        write(duplicate, """{"a":{"a":$MODEL_A,"a":$MODEL_A}}""")
        @test_throws ErrorException parse_models_json(duplicate)

        trailing = joinpath(dir, "trailing.json")
        write(trailing, """{"a":{"a":$MODEL_A}} trailing""")
        @test_throws ErrorException parse_models_json(trailing)

        # Undispatchable apis are filtered out of the emitted catalog.
        mixed = joinpath(dir, "mixed.json")
        write(
            mixed,
            """{"a":{"a":$MODEL_A},"bedrock":{"m":$(replace(MODEL_B, "\"api\": \"anthropic-messages\"" => "\"api\": \"bedrock-converse-stream\"", "\"provider\": \"z\"" => "\"provider\": \"bedrock\"", "\"id\": \"b\"" => "\"id\": \"m\""))}}""",
        )
        filtered = generate(
            mixed,
            joinpath(dir, "filtered.jl");
            source_label = "fixture/mixed.json",
            describe = "fixture-rev",
            date = "2026-07-30",
        )
        @test filtered.models == 1
        @test filtered.providers == 1
        @test filtered.dropped == Dict("bedrock-converse-stream" => 1)
        @test !occursin("bedrock", read(joinpath(dir, "filtered.json"), String))

        # Filtering must not hide malformed model records.
        missing_api = joinpath(dir, "missing-api.json")
        malformed = replace(MODEL_A, "  \"api\": \"openai-responses\",\n" => "")
        write(missing_api, """{"a":{"a":$malformed},"z":{"b":$MODEL_B}}""")
        @test_throws ErrorException generate(missing_api, joinpath(dir, "missing-api.jl"))
    end
end

end
