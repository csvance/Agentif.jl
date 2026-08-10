using Test
using LLMTools
using Agentif
using LLMProviders
using JSON

# A tool argument declared with a Julia default is still a *required* field in
# the generated NamedTuple type unless its declared type admits `nothing`:
# JSONSchema marks it required, and omitting it fails to parse. Tool prose that
# advertises such an argument as optional therefore lies to the model, which
# then emits a call that cannot be parsed (found by fuzzing: `write_stdin`
# without `chars` failed twice before the model guessed to include it).
#
# Guard the contract directly: for every tool, whatever the schema does not list
# as required must actually parse when omitted.

"Field names the schema marks required (JSONSchema.Schema is opaque; go via JSON)."
function required_names(tool)
    T = Agentif.parameters(tool)
    schema = JSON.parse(JSON.json(LLMProviders.OpenAICompletions.schema(T)))
    return Set{String}(String.(get(schema, "required", String[])))
end

"Minimal argument JSON containing only the schema-required fields."
function required_only_json(tool)
    T = Agentif.parameters(tool)
    required = required_names(tool)
    args = Dict{String, Any}()
    for (name, FT) in zip(fieldnames(T), fieldtypes(T))
        String(name) in required || continue
        args[String(name)] = if FT <: Integer
            1
        elseif FT <: AbstractString
            "x"
        elseif FT <: Bool
            false
        else
            nothing
        end
    end
    return JSON.json(args)
end

@testset "optional tool arguments are omittable" begin
    mktempdir() do dir
        tools = AgentTool[]
        append!(tools, LLMTools.coding_tools(dir))
        append!(tools, LLMTools.read_only_tools(dir))
        append!(tools, LLMTools.web_tools())

        for tool in tools
            name = Agentif.tool_name(tool)
            T = Agentif.parameters(tool)
            @testset "$name" begin
                # Every field that is not schema-required must survive omission.
                # Parsing only the required fields is the exact JSON a
                # well-behaved model emits when it takes the defaults.
                args = required_only_json(tool)
                parsed = try
                    Agentif.parse_tool_arguments(args, T)
                catch e
                    nothing
                end
                @test parsed !== nothing
            end
        end
    end
end

@testset "write_stdin without chars reads pending output" begin
    mktempdir() do dir
        tools = LLMTools.create_terminal_tools(dir)
        exec_tool = tools[findfirst(t -> Agentif.tool_name(t) == "exec_command", tools)]
        ws_tool = tools[findfirst(t -> Agentif.tool_name(t) == "write_stdin", tools)]

        T = Agentif.parameters(ws_tool)
        # documented: `chars` optional, default "" (just read pending output)
        parsed = try
            Agentif.parse_tool_arguments("{\"session_id\":1}", T)
        catch
            nothing
        end
        @test parsed !== nothing

        # end-to-end: start a session, then poll it with no `chars` at all
        ET = Agentif.parameters(exec_tool)
        res = Agentif.invoke_parsed_tool(exec_tool, Agentif.parse_tool_arguments(
            JSON.json(Dict("cmd" => "cat", "yield_time_ms" => 300)), ET))
        payload = JSON.parse(res)
        sid = get(payload, "session_id", nothing)
        if sid !== nothing
            out = Agentif.invoke_parsed_tool(ws_tool, Agentif.parse_tool_arguments(
                JSON.json(Dict("session_id" => sid, "yield_time_ms" => 200)), T))
            parsedout = JSON.parse(out)
            @test parsedout["tool"] == "write_stdin"
            @test parsedout["ok"] == true
            LLMTools.reset_sessions_for_tests!(LLMTools.PTY_REGISTRY)
        end
    end
end
