using Test
using LLMTools

function noncontained_funcs(base_dir::AbstractString)
    tools = [
        LLMTools.create_read_tool(base_dir; contained = false),
        LLMTools.create_write_tool(base_dir; contained = false),
        LLMTools.create_edit_tool(base_dir; contained = false),
        LLMTools.create_ls_tool(base_dir; contained = false),
        LLMTools.create_find_tool(base_dir; contained = false),
        LLMTools.create_grep_tool(base_dir; contained = false),
    ]
    return Dict(tool.name => tool.func for tool in tools)
end

@testset "File tools: contained=false" begin
    mktempdir() do tmpdir
        funcs = noncontained_funcs(tmpdir)
        read_file = funcs["read"]
        write_file = funcs["write"]
        edit_file = funcs["edit"]
        ls_dir = funcs["ls"]
        find_files = funcs["find"]
        grep_files = funcs["grep"]

        @testset "absolute paths outside the base" begin
            mktempdir() do outside
                outside_file = joinpath(outside, "outside.txt")
                write(outside_file, "outside content\nsecond line")

                @test occursin("Successfully wrote", write_file(joinpath(outside, "new.txt"), "fresh"))
                @test occursin("outside content", read_file(outside_file, nothing, nothing))
                @test occursin("Successfully replaced text", edit_file(joinpath(outside, "new.txt"), "fresh", "newer"))
                @test occursin("outside.txt", ls_dir(outside, 50, nothing))
                @test occursin("outside.txt", find_files("*.txt", outside, 20, nothing))
                @test occursin("outside.txt:1: outside content", grep_files("outside", outside, nothing, nothing, nothing, 0, 20, nothing))
                @test occursin("newer", grep_files("newer", joinpath(outside, "new.txt"), nothing, nothing, true, 0, 10, nothing))
            end
        end

        @testset "home paths expand to homedir" begin
            home_file = joinpath(homedir(), "agentif_contained_$(string(Base.rand(UInt32))).txt")
            write(home_file, "home content")
            try
                @test LLMTools.resolve_relative_path(tmpdir, "~"; contained = false) === homedir()
                @test LLMTools.resolve_relative_path(tmpdir, "~/" * basename(home_file); contained = false) == home_file
                @test occursin("home content", read_file("~/" * basename(home_file), nothing, nothing))
                @test occursin(basename(home_file), ls_dir("~", 1000, nothing))
                @test occursin(basename(home_file), find_files("agentif_contained_*.txt", "~", 10, nothing))
            finally
                isfile(home_file) && rm(home_file)
            end
        end

        @testset "relative paths stay base-anchored" begin
            @test occursin("Successfully wrote", write_file("inside.txt", "inside"))
            @test isfile(joinpath(tmpdir, "inside.txt"))
            @test read_file("inside.txt", nothing, nothing) == "inside"
            @test occursin("inside.txt", ls_dir(".", 50, nothing))
        end

        @testset "in-base absolute paths work in both modes" begin
            @test LLMTools.resolve_relative_path(tmpdir, joinpath(tmpdir, "a")) == joinpath(tmpdir, "a")
            @test LLMTools.resolve_relative_path(tmpdir, joinpath(tmpdir, "a"); contained = false) == joinpath(tmpdir, "a")
        end

        @testset "outside tree keeps its own gitignore treatment" begin
            mktempdir() do outside
                write(joinpath(outside, ".gitignore"), "ignored.txt\n")
                write(joinpath(outside, "ignored.txt"), "x")
                write(joinpath(outside, "kept.txt"), "y")
                listing = ls_dir(outside, 50, nothing)
                @test occursin("kept.txt", listing)
                @test !occursin("ignored.txt", listing)
                listing = ls_dir(outside, 50, true)
                @test occursin("ignored.txt", listing)
            end
        end

        @testset "contained tools keep refusing escapes" begin
            mktempdir() do outside
                outside_file = joinpath(outside, "outside.txt")
                write(outside_file, "outside content")
                @test_throws ArgumentError LLMTools.create_read_tool(tmpdir).func(outside_file, nothing, nothing)
                @test_throws ArgumentError LLMTools.create_ls_tool(tmpdir).func("~", 10, nothing)
            end
        end

        @testset "descriptions" begin
            desc = LLMTools.create_read_tool(tmpdir).description
            @test occursin("relative to the working directory, or absolute within it", desc)
            for (tool, contained) in (
                (LLMTools.create_read_tool(tmpdir; contained = false), false),
                (LLMTools.create_write_tool(tmpdir; contained = false), false),
                (LLMTools.create_edit_tool(tmpdir; contained = false), false),
                (LLMTools.create_ls_tool(tmpdir; contained = false), false),
                (LLMTools.create_find_tool(tmpdir; contained = false), false),
                (LLMTools.create_grep_tool(tmpdir; contained = false), false),
            )
                @test !occursin("or absolute within it", tool.description)
                @test occursin(
                    "relative to the working directory, absolute, or starting with `~` (expanded to your home directory)",
                    tool.description,
                )
            end
        end

        @testset "suite constructors propagate the flag" begin
            mktempdir() do outside
                outside_file = joinpath(outside, "suite.txt")
                write(outside_file, "suite content")

                ro = Dict(tool.name => tool.func for tool in LLMTools.read_only_tools(tmpdir; contained = false))
                @test occursin("suite content", ro["read"](outside_file, nothing, nothing))
                @test occursin("suite.txt", ro["ls"](outside, 50, nothing))
                @test occursin("suite.txt", ro["find"]("*.txt", outside, 10, nothing))
                @test occursin("suite.txt:1: suite content", ro["grep"]("suite", outside, nothing, nothing, nothing, 0, 10, nothing))

                ct = Dict(tool.name => tool.func for tool in LLMTools.coding_tools(tmpdir; contained = false))
                @test occursin("Successfully wrote", ct["write"](outside_file, "rewritten"))
                @test occursin("rewritten", ct["read"](outside_file, nothing, nothing))

                at = LLMTools.all_tools(tmpdir; contained = false)
                @test occursin("rewritten", at["read"].func(outside_file, nothing, nothing))

                # The default remains contained.
                ro_default = Dict(tool.name => tool.func for tool in LLMTools.read_only_tools(tmpdir))
                @test_throws ArgumentError ro_default["read"](outside_file, nothing, nothing)
            end
        end
    end
end
