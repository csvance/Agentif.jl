# How ls, find and grep integrate with GitIgnore.jl. Pattern semantics belong to
# that package and are tested there, differentially against the real git binary;
# what matters here is that the three tools agree with each other, that
# `includeIgnored` turns the filtering off, that a path the caller names is
# reachable even when the rules exclude it, and that the notices tell the model
# why a result is empty.

using Test, LLMTools

function search_funcs(base_dir::AbstractString)
    tools = [
        LLMTools.create_ls_tool(base_dir),
        LLMTools.create_find_tool(base_dir),
        LLMTools.create_grep_tool(base_dir),
    ]
    return Dict(tool.name => tool.func for tool in tools)
end

# The repository laid out by most tests below.
function build_ignore_fixture(dir::AbstractString)
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "build", "deep"))
    mkpath(joinpath(dir, "vendor"))
    mkpath(joinpath(dir, ".git", "objects"))
    write(joinpath(dir, ".gitignore"), "build/\n*.log\n!keep.log\nvendor\n")
    write(joinpath(dir, "top.jl"), "needle top\n")
    write(joinpath(dir, "keep.log"), "needle kept\n")
    write(joinpath(dir, "src", "main.jl"), "needle src\n")
    write(joinpath(dir, "src", "app.log"), "needle log\n")
    write(joinpath(dir, "build", "out.jl"), "needle built\n")
    write(joinpath(dir, "build", "deep", "x.jl"), "needle deep\n")
    write(joinpath(dir, "vendor", "lib.jl"), "needle vendored\n")
    write(joinpath(dir, ".git", "objects", "blob"), "needle git\n")
    return nothing
end

@testset "ls/find/grep honour .gitignore" begin
    mktempdir() do dir
        build_ignore_fixture(dir)
        funcs = search_funcs(dir)
        ls_dir, find_files, grep_files = funcs["ls"], funcs["find"], funcs["grep"]

        @testset "ls" begin
            listing = ls_dir(".", nothing, nothing)
            @test occursin("top.jl", listing)
            @test occursin("keep.log", listing)
            @test occursin("src/", listing)
            @test !occursin("build/", listing)
            @test !occursin("vendor/", listing)
            @test !occursin(".git/", listing)
            # The count tells the model the directory is not as small as it looks.
            @test occursin("hidden by .gitignore", listing)

            with_ignored = ls_dir(".", nothing, true)
            @test occursin("build/", with_ignored)
            @test occursin("vendor/", with_ignored)
            # `.git` stays hidden even then, and is not counted as a gitignore hit.
            @test !occursin(".git/", with_ignored)
            @test !occursin("hidden by .gitignore", with_ignored)

            # A directory the caller names is listed even though it is ignored,
            # which is the same exemption find and grep give their start path.
            explicit = ls_dir("build", nothing, nothing)
            @test occursin("out.jl", explicit)
            @test occursin("deep/", explicit)
            @test !occursin("hidden by .gitignore", explicit)
        end

        @testset "find" begin
            found = find_files("**/*.jl", nothing, nothing, nothing)
            @test occursin("src/main.jl", found)
            @test !occursin("build/out.jl", found)
            @test !occursin("build/deep/x.jl", found)
            @test !occursin("vendor/lib.jl", found)

            with_ignored = find_files("**/*.jl", nothing, nothing, true)
            @test occursin("build/out.jl", with_ignored)
            @test occursin("build/deep/x.jl", with_ignored)
            @test occursin("vendor/lib.jl", with_ignored)

            # Nothing from inside .git, with or without the flag.
            @test !occursin(".git", find_files("**/blob", nothing, nothing, true))

            # An empty result says why it might be empty.
            @test occursin("includeIgnored", find_files("*.nope", nothing, nothing, nothing))
        end

        @testset "grep" begin
            matches = grep_files("needle", nothing, nothing, nothing, nothing, nothing, nothing, nothing)
            @test occursin("top.jl:1:", matches)
            @test occursin("keep.log:1:", matches)
            @test occursin("src/main.jl:1:", matches)
            @test !occursin("src/app.log", matches)
            @test !occursin("build/out.jl", matches)
            @test !occursin("vendor/lib.jl", matches)
            @test !occursin(".git", matches)

            with_ignored = grep_files("needle", nothing, nothing, nothing, nothing, nothing, nothing, true)
            @test occursin("src/app.log", with_ignored)
            @test occursin("build/out.jl", with_ignored)
            @test occursin("build/deep/x.jl", with_ignored)
            @test occursin("vendor/lib.jl", with_ignored)
            # Still nothing out of .git.
            @test !occursin("objects/blob", with_ignored)

            # A file the caller names is searched whether it is ignored or not,
            # and that answer must not blame the ignore rules for a non-match.
            named = grep_files("needle", "build/out.jl", nothing, nothing, nothing, nothing, nothing, nothing)
            @test occursin("out.jl:1:", named)
            @test grep_files("absent", "build/out.jl", nothing, nothing, nothing, nothing, nothing, nothing) ==
                  "No matches found"

            # A directory the caller names is walked, with its own rules applying.
            in_build = grep_files("needle", "build", nothing, nothing, nothing, nothing, nothing, nothing)
            @test occursin("out.jl:1:", in_build)
            @test occursin("deep/x.jl:1:", in_build)
        end
    end
end

@testset "the three tools agree on one tree" begin
    mktempdir() do dir
        build_ignore_fixture(dir)
        funcs = search_funcs(dir)
        # src/app.log is excluded, src/main.jl is not. Every tool has to say so.
        @test occursin("main.jl", funcs["ls"]("src", nothing, nothing))
        @test !occursin("app.log", funcs["ls"]("src", nothing, nothing))
        @test occursin("src/main.jl", funcs["find"]("**/*", nothing, nothing, nothing))
        @test !occursin("src/app.log", funcs["find"]("**/*", nothing, nothing, nothing))
        matches = funcs["grep"]("needle", nothing, nothing, nothing, nothing, nothing, nothing, nothing)
        @test occursin("src/main.jl", matches)
        @test !occursin("src/app.log", matches)
    end
end

@testset "notices survive the entry limit and do not misattribute" begin
    mktempdir() do dir
        write(joinpath(dir, ".gitignore"), "*.log\n")
        for i in 1:5
            write(joinpath(dir, "a$(i).txt"), "x")
            write(joinpath(dir, "z$(i).log"), "x")
        end
        funcs = search_funcs(dir)
        # The hidden count must describe the whole directory, not the prefix the
        # entry limit happened to leave room for.
        limited = funcs["ls"](".", 3, nothing)
        @test occursin("entries limit reached", limited)
        @test occursin("5 entries hidden by .gitignore", limited)

        # When the rules did remove something, the hint is earned.
        @test occursin("includeIgnored", funcs["grep"]("nomatchanywhere", nothing, nothing, nothing, nothing, nothing, nothing, nothing))
    end

    # A tree where the rules exist but exclude nothing: the empty-result hint
    # must not blame them when the glob or the pattern is the real reason.
    mktempdir() do dir
        write(joinpath(dir, ".gitignore"), "*.log\n")
        write(joinpath(dir, "a.txt"), "x")
        funcs = search_funcs(dir)
        @test funcs["grep"]("x", nothing, "*.nope", nothing, nothing, nothing, nothing, nothing) ==
              "No matches found"
        @test funcs["grep"]("nomatchanywhere", nothing, nothing, nothing, nothing, nothing, nothing, nothing) ==
              "No matches found"
        @test funcs["find"]("*.nope", nothing, nothing, nothing) == "No files found matching pattern"
    end
end

@testset "a fully ignored directory is not reported as empty" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "logs"))
        write(joinpath(dir, ".gitignore"), "*.log\n")
        write(joinpath(dir, "logs", "a.log"), "x")
        funcs = search_funcs(dir)
        listing = funcs["ls"]("logs", nothing, nothing)
        @test !occursin("(empty directory)", listing)
        @test occursin("hidden by .gitignore", listing)
    end
end

@testset "an ignored directory is never descended into" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "node_modules", "deep", "deeper"))
        write(joinpath(dir, ".gitignore"), "node_modules/\n")
        write(joinpath(dir, "src", "keep.jl"), "x\n")
        write(joinpath(dir, "node_modules", "deep", "deeper", "a.jl"), "x\n")
        funcs = search_funcs(dir)
        found = funcs["find"]("**/*.jl", nothing, nothing, nothing)
        @test occursin("src/keep.jl", found)
        @test !occursin("node_modules", found)
        # A pruned directory is one skipped entry, not one per file inside it.
        @test occursin("includeIgnored", funcs["find"]("*.nope", nothing, nothing, nothing))
    end
end

@testset "rules below the base directory still apply" begin
    # An agent started in a home directory walks into a repository, and that
    # repository's rules have to take effect from where they were found.
    mktempdir() do home
        repo = joinpath(home, "Git", "proj")
        mkpath(joinpath(repo, "build"))
        write(joinpath(repo, ".gitignore"), "build/\n")
        write(joinpath(repo, "main.jl"), "x\n")
        write(joinpath(repo, "build", "out.o"), "x\n")
        mkpath(joinpath(home, "notes"))
        write(joinpath(home, "notes", "todo.md"), "x\n")
        funcs = search_funcs(home)
        found = funcs["find"]("**/*", nothing, nothing, nothing)
        # A sibling tree with no rules of its own is untouched.
        @test occursin("notes/todo.md", found)
        @test occursin("Git/proj/main.jl", found)
        @test !occursin("build/out.o", found)
    end
end

@testset ".git/info/exclude is honoured" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "info"))
        write(joinpath(dir, ".git", "info", "exclude"), "hidden.txt\n")
        write(joinpath(dir, "hidden.txt"), "x\n")
        write(joinpath(dir, "shown.txt"), "x\n")
        funcs = search_funcs(dir)
        found = funcs["find"]("*.txt", nothing, nothing, nothing)
        @test occursin("shown.txt", found)
        @test !occursin("hidden.txt", found)
    end
end

@testset ".git is skipped without any .gitignore present" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "objects"))
        write(joinpath(dir, ".git", "objects", "blob"), "secret\n")
        write(joinpath(dir, "a.jl"), "code\n")
        funcs = search_funcs(dir)
        @test !occursin(".git", funcs["ls"](".", nothing, nothing))
        @test !occursin("blob", funcs["find"]("**/*", nothing, nothing, nothing))
        @test !occursin("secret", funcs["grep"]("secret", nothing, nothing, nothing, nothing, nothing, nothing, nothing))
        # Naming it explicitly still works, the way `rg .git` does.
        @test occursin("secret", funcs["grep"]("secret", ".git", nothing, nothing, nothing, nothing, nothing, nothing))
    end
end

@testset "an unreadable directory does not fail the walk" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "locked"))
        write(joinpath(dir, "locked", "hidden.jl"), "x\n")
        write(joinpath(dir, "visible.jl"), "x\n")
        chmod(joinpath(dir, "locked"), 0o000)
        try
            funcs = search_funcs(dir)
            # The walk still descends into `locked/` and has to survive it; the
            # glob only decides what gets reported.
            found = funcs["find"]("*.jl", nothing, nothing, nothing)
            @test occursin("visible.jl", found)
        finally
            chmod(joinpath(dir, "locked"), 0o700)
        end
    end
end
