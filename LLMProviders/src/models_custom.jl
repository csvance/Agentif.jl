# Custom model registry entries that are not generated.

function _init_custom_models!()
    google_gemini_cli_models = Dict{String, Model}(
        "gemini-2.0-flash" => Model(
            id = "gemini-2.0-flash",
            name = "Gemini 2.0 Flash (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = false,
            input = ["text", "image"],
            contextWindow = 1048576,
            maxTokens = 8192,
            headers = nothing
        ),
        "gemini-2.5-flash" => Model(
            id = "gemini-2.5-flash",
            name = "Gemini 2.5 Flash (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-2.5-pro" => Model(
            id = "gemini-2.5-pro",
            name = "Gemini 2.5 Pro (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-3-flash-preview" => Model(
            id = "gemini-3-flash-preview",
            name = "Gemini 3 Flash Preview (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
        "gemini-3-pro-preview" => Model(
            id = "gemini-3-pro-preview",
            name = "Gemini 3 Pro Preview (Cloud Code Assist)",
            api = "google-gemini-cli",
            provider = "google-gemini-cli",
            baseUrl = "https://cloudcode-pa.googleapis.com",
            reasoning = true,
            input = ["text", "image"],
            contextWindow = 1048576,
            maxTokens = 65535,
            headers = nothing
        ),
    )
    merge!(get!(() -> Dict{String, Model}(), _model_registry, "google-gemini-cli"), google_gemini_cli_models)

    # OpenAI Codex models (via ChatGPT OAuth)
    function codex_model(
            model_id::String,
            name::String;
            context_window::Int = 272000,
            max_tokens::Int = 128000,
        )
        return Model(
            id = model_id,
            name = name,
            api = "openai-codex-responses",
            provider = "openai-codex",
            baseUrl = "https://chatgpt.com/backend-api",
            reasoning = true,
            input = ["text", "image"],
            contextWindow = context_window,
            maxTokens = max_tokens,
            headers = nothing,
        )
    end
    openai_codex_models = Dict{String, Model}(
        "gpt-5-codex" => codex_model("gpt-5-codex", "GPT-5 Codex"),
        "gpt-5.1" => codex_model("gpt-5.1", "GPT-5.1"),
        "gpt-5.1-codex" => codex_model("gpt-5.1-codex", "GPT-5.1 Codex"),
        "gpt-5.1-codex-max" => codex_model("gpt-5.1-codex-max", "GPT-5.1 Codex Max"),
        "gpt-5.1-codex-mini" => codex_model("gpt-5.1-codex-mini", "GPT-5.1 Codex Mini"),
        "gpt-5.2" => codex_model("gpt-5.2", "GPT-5.2"),
        "gpt-5.2-codex" => codex_model("gpt-5.2-codex", "GPT-5.2 Codex"),
        "gpt-5.3-codex" => codex_model("gpt-5.3-codex", "GPT-5.3 Codex"; context_window = 400000),
        "gpt-5.3-codex-spark" => codex_model(
            "gpt-5.3-codex-spark",
            "GPT-5.3 Codex Spark";
            context_window = 128000,
            max_tokens = 32000,
        ),
        "gpt-5.4" => codex_model("gpt-5.4", "GPT-5.4"),
    )
    merge!(get!(() -> Dict{String, Model}(), _model_registry, "openai-codex"), openai_codex_models)
    return nothing
end

_init_custom_models!()
