#!/usr/bin/env julia
using Agentif
using LLMTools

const DEFAULT_PROVIDER = get(ENV, "AGENTIF_PROVIDER", "openai")
const DEFAULT_MODEL = get(ENV, "AGENTIF_MODEL", "gpt-4.1-mini")

function resolve_api_key()
    apikey = get(ENV, "AGENTIF_API_KEY", "")
    isempty(apikey) && error("Set AGENTIF_API_KEY to run this example.")
    return apikey
end

function build_agent(base_dir::AbstractString = pwd())
    model = getModel(DEFAULT_PROVIDER, DEFAULT_MODEL)
    model === nothing && error("Unknown model: provider=$(repr(DEFAULT_PROVIDER)) model_id=$(repr(DEFAULT_MODEL))")

    tools = LLMTools.coding_tools(base_dir)
    skill_registry = create_skill_registry(default_skill_dirs(base_dir))
    if !isempty(skill_registry.skills)
        push!(tools, create_skill_loader_tool(skill_registry))
    end

    agent = Agent(
        prompt = "You are a helpful coding assistant. Explore before editing, prefer concise answers, and explain tool-driven changes clearly.",
        model = model,
        apikey = resolve_api_key(),
        tools = tools,
    )

    return agent, skill_registry
end

function handle_event(event)
    if event isa MessageUpdateEvent && event.role == :assistant
        if event.kind == :text || event.kind == :reasoning
            print(event.delta)
            flush(stdout)
        end
    elseif event isa ToolExecutionStartEvent
        println("\n[tool] $(event.tool_call.name)")
    elseif event isa ToolExecutionEndEvent
        println("[tool] $(event.tool_call.name) complete")
    elseif event isa AgentErrorEvent
        println("\n[error] $(event.error)")
    end
    return nothing
end

function main()
    agent, skill_registry = build_agent()
    state = AgentState()

    println("Agentif coding agent ready. Type 'exit' to quit.")
    while true
        print("> ")
        input = strip(readline())
        isempty(input) && continue
        input in ("exit", "quit") && break

        state = evaluate(handle_event, agent, input; state, skill_registry)
        println()
    end
end

main()
