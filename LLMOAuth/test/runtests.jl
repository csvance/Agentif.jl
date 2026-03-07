using Test
using JSON
using Base64
using Dates
using LLMOAuth
using OAuth

function fake_jwt(payload::AbstractDict)
    encoded = Base64.base64encode(JSON.json(payload))
    encoded = replace(encoded, '+' => '-', '/' => '_')
    encoded = replace(encoded, "=" => "")
    return "header.$encoded.signature"
end

@testset "Codex JWT parsing" begin
    token = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-123")))
    payload = LLMOAuth.codex_decode_jwt(token)
    claims = get(() -> nothing, payload, "https://api.openai.com/auth")
    @test claims !== nothing
    @test get(() -> nothing, claims, "chatgpt_account_id") == "acct-123"
    @test LLMOAuth.codex_get_account_id(token) == "acct-123"

    bad = fake_jwt(Dict("sub" => "user"))
    @test_throws ErrorException LLMOAuth.codex_get_account_id(bad)
end

@testset "Codex auth input parsing" begin
    @test LLMOAuth.parse_codex_authorization_input("abc123") == ("abc123", "")
    @test LLMOAuth.parse_codex_authorization_input("abc123#state-1") == ("abc123", "state-1")
    @test LLMOAuth.parse_codex_authorization_input("code=abc123&state=state-1") == ("abc123", "state-1")
    @test LLMOAuth.parse_codex_authorization_input(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
    ) == ("abc123", "state-1")
end

@testset "Codex manual auth fallback helpers" begin
    @test LLMOAuth.codex_manual_authorization_code(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
        "state-1";
        input_provider = () -> "http://localhost:1455/auth/callback?code=abc123&state=state-1",
    ) == "abc123"

    @test_throws ArgumentError LLMOAuth.codex_manual_authorization_code(
        "http://localhost:1455/auth/callback?code=abc123&state=state-1",
        "state-1";
        input_provider = () -> "abc123#wrong-state",
    )
end

@testset "Codex refresh token preservation" begin
    access = fake_jwt(Dict("https://api.openai.com/auth" => Dict("chatgpt_account_id" => "acct-xyz")))
    issued_at = Dates.now(Dates.UTC)
    token = OAuth.TokenResponse(
        access_token = access,
        token_type = "Bearer",
        expires_at = issued_at + Dates.Second(3600),
        refresh_token = nothing,
        scope = nothing,
        id_token = nothing,
        dpop_jkt = nothing,
        dpop_nonce = nothing,
        authorization_details = nothing,
        resource = String[],
        issued_token_type = nothing,
        extra = Dict{String, Any}(),
        raw = JSON.parse("{}"),
    )
    creds = LLMOAuth.codex_credentials_from_token(token; existing_refresh_token = "refresh-old")
    @test creds.refresh_token == "refresh-old"
    @test creds.account_id == "acct-xyz"
end
