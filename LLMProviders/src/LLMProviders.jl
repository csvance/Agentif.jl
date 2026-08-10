module LLMProviders

using HTTP, JSON, JSONSchema, StructUtils, UUIDs

# Include model definitions
include("models.jl")

# Include provider implementations
include("providers/openai_responses.jl")
include("providers/openai_completions.jl")
include("providers/anthropic_messages.jl")
include("providers/google_generative_ai.jl")
include("providers/google_gemini_cli.jl")

# Exports
export Model, getModel, getProviders, getModels, calculateCost, registerModel!, discover_models!
export OpenAIResponses, OpenAICompletions, AnthropicMessages, GoogleGenerativeAI, GoogleGeminiCli

end # module
