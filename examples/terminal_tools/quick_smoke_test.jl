#!/usr/bin/env julia
"""
Quick smoke test - runs a few key examples to verify basic functionality.
Use this for fast iteration during development.
"""

using Agentif, LLMTools
using PtySessions

function last_assistant_text(state::AgentState)
    idx = findlast(msg -> msg isa AssistantMessage, state.messages)
    idx === nothing && return ""
    return message_text(state.messages[idx])
end

println("="^80)
println("Quick Smoke Test for terminal_tools")
println("="^80)

# Test 1: Simple command execution
println("\n[1/3] Testing simple command execution...")
tools = LLMTools.create_terminal_tools()
agent = Agent(
    prompt = "Execute commands quickly and concisely.",
    model = getModel("anthropic", "claude-haiku-4-5"),  # Using faster model for smoke tests
    apikey = ENV["ANTHROPIC_API_KEY"],
    tools = tools,
)

result = evaluate(agent, "Execute: echo 'Test 1 PASS'")
@assert occursin("Test 1 PASS", last_assistant_text(result)) "Test 1 failed - echo command didn't work"
println("✅ Test 1 passed")

# Test 2: Working directory
println("\n[2/3] Testing working directory...")
result = evaluate(agent, "Run 'pwd' in the /tmp directory")
@assert occursin("tmp", lowercase(last_assistant_text(result))) "Test 2 failed - working directory not respected"
println("✅ Test 2 passed")

# Test 3: Multiple commands
println("\n[3/3] Testing multiple commands...")
result = evaluate(agent, "Run these 3 commands: echo 'First', echo 'Second', echo 'Third'")
@assert occursin("First", last_assistant_text(result)) || occursin("Second", last_assistant_text(result)) "Test 3 failed - multiple commands didn't work"
println("✅ Test 3 passed")

println("\n" * "="^80)
println("🎉 All smoke tests passed!")
println("="^80)
