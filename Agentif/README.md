# Agentif

`Agentif` is the core runtime for building LLM-powered Julia agents with middleware, tool calling, sessions, streaming events, skills, and provider adapters.

## Repo-Root Workflow

From the monorepo root:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then load the package:

```julia
using Agentif
```

## Basic Usage

`Agentif` provides the runtime and agent types. Tool suites such as `coding_tools()` and `read_only_tools()` live in `LLMTools`.

```julia
using Agentif, LLMTools

agent = Agent(
    prompt = "You are a helpful assistant.",
    model = getModel("openai", "gpt-4.1-mini"),
    apikey = ENV["OPENAI_API_KEY"],
    tools = LLMTools.read_only_tools(pwd()),
)

state = evaluate(agent, "List the files in the current directory.")
println(message_text(state.messages[end]))
```

To stream events as they happen:

```julia
using Agentif

state = evaluate(agent, "Say hello.") do event
    if event isa MessageUpdateEvent && event.role == :assistant && event.kind == :text
        print(event.delta)
    end
end
```

## Main Concepts

- `Agent`: prompt, model, API key, and tool list.
- `AgentState`: accumulated messages, usage, pending tool calls, and response metadata.
- `evaluate` / `stream`: run a turn against the configured model.
- `build_default_handler`: compose middleware for tools, sessions, skills, channels, and compaction.
- `@tool` and `AgentTool`: wrap Julia functions as callable tools.

## Related Packages

- `LLMTools` for ready-made tool suites.
- `LLMProviders` for model metadata and provider-specific request/response types.
- `LLMOAuth` for Codex/OpenAI and Anthropic OAuth helpers.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Agentif
```
