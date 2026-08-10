using Test
using LLMTools
using Agentif
using JSON

# Regressions from fuzzing the terminal tools with hostile subprocess output and
# model-supplied arguments.

@testset "tool output is always valid UTF-8" begin
    # A subprocess may emit arbitrary bytes; the result is JSON-encoded and sent
    # to a provider, so it must be valid UTF-8 regardless.
    raw = String(UInt8[0xff, 0xfe, 0x80, 0x41, 0x42, 0x00, 0xe2, 0x9c])
    @test !isvalid(raw)

    proj = LLMTools.project_output(raw, 100, 1000)
    @test isvalid(proj.raw_output)
    @test isvalid(proj.output)

    @test isvalid(LLMTools.truncate_tool_output(raw; label = "Output"))

    # valid multi-byte text must survive untouched
    ok = "héllo ✓ 日本語 \U0001f389"
    @test LLMTools.project_output(ok, 100, 1000).output == ok
    @test occursin("日本語", LLMTools.truncate_tool_output(ok; label = "Output"))
end

@testset "exec_command with binary output stays encodable" begin
    mktempdir() do dir
        tools = LLMTools.create_terminal_tools(dir)
        exec_tool = tools[findfirst(t -> Agentif.tool_name(t) == "exec_command", tools)]
        T = Agentif.parameters(exec_tool)
        res = Agentif.invoke_parsed_tool(exec_tool, Agentif.parse_tool_arguments(
            JSON.json(Dict("cmd" => "head -c 2000 /dev/urandom", "yield_time_ms" => 1500)), T))
        @test isvalid(res)
        @test JSON.parse(res)["tool"] == "exec_command"
        LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
    end
end

@testset "a fast command returns without burning its yield window" begin
    mktempdir() do dir
        tools = LLMTools.create_terminal_tools(dir)
        exec_tool = tools[findfirst(t -> Agentif.tool_name(t) == "exec_command", tools)]
        T = Agentif.parameters(exec_tool)
        # yield_time_ms is a ceiling on waiting for a *running* process, not a
        # fixed delay: `echo` finishes at once and must not cost 20s.
        elapsed = @elapsed res = Agentif.invoke_parsed_tool(exec_tool,
            Agentif.parse_tool_arguments(
                JSON.json(Dict("cmd" => "echo quick", "yield_time_ms" => 20_000)), T))
        parsed = JSON.parse(res)
        @test parsed["status"] == LLMTools.SESSION_STATUS_EXITED
        @test occursin("quick", parsed["output"])
        @test elapsed < 10
        LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
    end
end

@testset "model-supplied yield_time_ms cannot hang the agent" begin
    mktempdir() do dir
        tools = LLMTools.create_terminal_tools(dir)
        exec_tool = tools[findfirst(t -> Agentif.tool_name(t) == "exec_command", tools)]
        T = Agentif.parameters(exec_tool)
        # typemax(Int) ms is ~292 million years; unclamped this never returns
        task = Threads.@spawn Agentif.invoke_parsed_tool(exec_tool,
            Agentif.parse_tool_arguments(
                JSON.json(Dict("cmd" => "echo hi", "yield_time_ms" => typemax(Int))), T))
        finished = timedwait(() -> istaskdone(task), 60.0; pollint = 0.1) !== :timed_out
        @test finished
        if finished
            @test JSON.parse(fetch(task))["tool"] == "exec_command"
        end
        @test LLMTools.MAX_YIELD_TIME_MS <= 600_000
        LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
    end
end
