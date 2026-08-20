using Test
using LLMTools
using LLMTools: IgnoreContext, IgnoreRules, ignore_context, ignore_glob_to_regex,
                is_ignored, parse_ignore_line, path_ignored, walk_filtered

function search_funcs(base_dir::AbstractString)
    tools = [
        LLMTools.create_ls_tool(base_dir),
        LLMTools.create_find_tool(base_dir),
        LLMTools.create_grep_tool(base_dir),
    ]
    return Dict(tool.name => tool.func for tool in tools)
end

# The repository laid out by every behavioural test below.
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

# A context whose only rules are the ones spelled out here, so pattern semantics
# can be checked without touching the filesystem.
rules_from(lines::Vector{String}; prefix::AbstractString = "") =
    IgnoreRules(prefix, filter(!isnothing, [parse_ignore_line(l) for l in lines]))

@testset "gitignore line parsing" begin
    @test parse_ignore_line("") === nothing
    @test parse_ignore_line("   ") === nothing
    @test parse_ignore_line("# a comment") === nothing
    @test parse_ignore_line("!") === nothing
    @test parse_ignore_line("/") === nothing

    negated = parse_ignore_line("!keep.log")
    @test negated.negated
    @test !negated.dir_only

    dir_only = parse_ignore_line("build/")
    @test dir_only.dir_only
    @test !dir_only.negated

    # An escaped leading `#` is a filename, not a comment.
    literal_hash = parse_ignore_line("\\#notes")
    @test literal_hash !== nothing
    @test occursin(literal_hash.regex, "#notes")

    # Trailing whitespace is dropped unless a backslash quotes it.
    @test occursin(parse_ignore_line("trailing.txt   ").regex, "trailing.txt")
    @test occursin(parse_ignore_line("space\\ ").regex, "space ")
end

@testset "gitignore pattern semantics" begin
    # No separator: matches a basename at any depth.
    anywhere = rules_from(["*.log"])
    @test path_ignored([anywhere], "a.log", false)
    @test path_ignored([anywhere], "deep/nested/a.log", false)
    @test !path_ignored([anywhere], "a.logs", false)

    # A separator anchors the pattern to the declaring directory.
    anchored = rules_from(["src/*.jl"])
    @test path_ignored([anchored], "src/main.jl", false)
    @test !path_ignored([anchored], "lib/src/main.jl", false)

    # A leading slash anchors without making the pattern recursive.
    rooted = rules_from(["/top.jl"])
    @test path_ignored([rooted], "top.jl", false)
    @test !path_ignored([rooted], "src/top.jl", false)

    # `*` stops at a separator, `**` crosses it.
    single = rules_from(["a/*/c"])
    @test path_ignored([single], "a/b/c", false)
    @test !path_ignored([single], "a/b/x/c", false)
    double = rules_from(["a/**/c"])
    @test path_ignored([double], "a/b/c", false)
    @test path_ignored([double], "a/b/x/c", false)
    # `**/` also matches zero segments.
    @test path_ignored([double], "a/c", false)

    # A trailing `/**` is everything inside, but not the directory itself.
    inside = rules_from(["logs/**"])
    @test path_ignored([inside], "logs/a.txt", false)
    @test path_ignored([inside], "logs/deep/a.txt", false)
    @test !path_ignored([inside], "logs", true)

    # A trailing slash restricts the pattern to directories.
    dirs_only = rules_from(["build/"])
    @test path_ignored([dirs_only], "build", true)
    @test !path_ignored([dirs_only], "build", false)

    # `?` is one non-separator character; a bracket expression is a class.
    @test path_ignored([rules_from(["a?c.jl"])], "abc.jl", false)
    @test !path_ignored([rules_from(["a?c.jl"])], "a/c.jl", false)
    @test path_ignored([rules_from(["[abc].txt"])], "b.txt", false)
    @test !path_ignored([rules_from(["[abc].txt"])], "d.txt", false)
    @test path_ignored([rules_from(["[!abc].txt"])], "d.txt", false)
    @test !path_ignored([rules_from(["[!abc].txt"])], "b.txt", false)

    # A `.` in a pattern is a literal dot, not a regex wildcard.
    @test !path_ignored([rules_from(["a.txt"])], "axtxt", false)

    # Within one file the last matching line wins, both ways round.
    @test !path_ignored([rules_from(["*.log", "!keep.log"])], "keep.log", false)
    @test path_ignored([rules_from(["!keep.log", "*.log"])], "keep.log", false)

    # An unterminated `[` is a literal bracket.
    @test path_ignored([rules_from(["a[b.txt"])], "a[b.txt", false)
end

@testset "nested .gitignore precedence" begin
    outer = rules_from(["*.jl"])
    inner = rules_from(["!*.jl"]; prefix = "src")
    # The deeper file wins inside its own subtree only.
    @test !path_ignored([outer, inner], "src/main.jl", false)
    @test path_ignored([outer, inner], "lib/main.jl", false)
    # A sibling whose name merely starts with the prefix is not in that subtree.
    @test path_ignored([outer, inner], "srclib/main.jl", false)
end

@testset "non-ASCII ignore patterns" begin
    # A byte-stepped loop would throw StringIndexError on any of these.
    @test occursin(ignore_glob_to_regex("café*", false), "café-notes")
    @test occursin(ignore_glob_to_regex("ünïcode?.txt", false), "ünïcodeX.txt")
    @test path_ignored([rules_from(["日本/*.md"])], "日本/notes.md", false)
end

@testset "ls/find/grep honour .gitignore" begin
    mktempdir() do dir
        build_ignore_fixture(dir)
        funcs = search_funcs(dir)
        ls_dir = funcs["ls"]
        find_files = funcs["find"]
        grep_files = funcs["grep"]

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

            # A directory the caller names is listed even though it is ignored.
            explicit = ls_dir("build", nothing, nothing)
            @test occursin("out.jl", explicit)
            @test occursin("deep/", explicit)
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

@testset "nested .gitignore applies to its subtree" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "pkg", "src"))
        mkpath(joinpath(dir, "other"))
        write(joinpath(dir, ".gitignore"), "*.tmp\n")
        write(joinpath(dir, "pkg", ".gitignore"), "!important.tmp\nlocal/\n")
        mkpath(joinpath(dir, "pkg", "local"))
        write(joinpath(dir, "pkg", "important.tmp"), "kept\n")
        write(joinpath(dir, "pkg", "scratch.tmp"), "dropped\n")
        write(joinpath(dir, "pkg", "local", "cache.jl"), "dropped\n")
        write(joinpath(dir, "other", "important.tmp"), "dropped\n")
        write(joinpath(dir, "pkg", "src", "main.jl"), "kept\n")

        find_files = search_funcs(dir)["find"]
        found = find_files("**/*", nothing, nothing, nothing)
        @test occursin("pkg/important.tmp", found)
        @test occursin("pkg/src/main.jl", found)
        @test !occursin("pkg/scratch.tmp", found)
        @test !occursin("pkg/local", found)
        # The re-inclusion is scoped to pkg/, so the same name elsewhere stays out.
        @test !occursin("other/important.tmp", found)
    end
end

@testset "a .gitignore found below the base directory governs its own subtree" begin
    # The base directory is not a repository: an agent started in a home
    # directory walks into one, and that repository's rules have to take effect
    # from where they were found, apply all the way down, anchor to the
    # repository rather than to the base, and not leak to a sibling tree.
    mktempdir() do home
        repo = joinpath(home, "Git", "Agentif.jl")
        mkpath(joinpath(repo, "Claw", "src"))
        mkpath(joinpath(repo, "Claw", "build"))
        mkpath(joinpath(repo, "LLMTools"))
        mkpath(joinpath(repo, ".git"))
        mkpath(joinpath(home, "Documents"))
        write(joinpath(repo, ".gitignore"), "*.jl.cov\n/Claw/Manifest.toml\nbuild/\n")
        write(joinpath(repo, "top.jl"), "x")
        write(joinpath(repo, "top.jl.cov"), "x")
        write(joinpath(repo, "Claw", "src", "keep.jl"), "x")
        write(joinpath(repo, "Claw", "src", "deep.jl.cov"), "x")
        write(joinpath(repo, "Claw", "Manifest.toml"), "x")
        write(joinpath(repo, "LLMTools", "Manifest.toml"), "x")
        write(joinpath(repo, "Claw", "build", "obj.jl"), "x")
        write(joinpath(repo, ".git", "HEAD"), "x")
        write(joinpath(home, "Documents", "notes.jl"), "x")
        write(joinpath(home, "Documents", "notes.jl.cov"), "x")

        found = search_funcs(home)["find"]("**/*", nothing, 200, nothing)
        @test occursin("Git/Agentif.jl/top.jl\n", found)
        @test occursin("Git/Agentif.jl/Claw/src/keep.jl", found)
        # Unanchored, at the declaring directory and three levels below it.
        @test !occursin("top.jl.cov", found)
        @test !occursin("deep.jl.cov", found)
        # Anchored to the repository, so the same basename elsewhere survives.
        @test !occursin("Claw/Manifest.toml", found)
        @test occursin("LLMTools/Manifest.toml", found)
        # A directory rule prunes, and `.git` is gone either way.
        @test !occursin("build", found)
        @test !occursin(".git/", found)
        # The repository's rules stop at the repository.
        @test occursin("Documents/notes.jl.cov", found)
    end
end

@testset ".git/info/exclude is honoured" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "info"))
        write(joinpath(dir, ".git", "info", "exclude"), "secret.txt\n")
        write(joinpath(dir, "secret.txt"), "hidden\n")
        write(joinpath(dir, "public.txt"), "shown\n")

        funcs = search_funcs(dir)
        listing = funcs["ls"](".", nothing, nothing)
        @test occursin("public.txt", listing)
        @test !occursin("secret.txt", listing)
        @test occursin("secret.txt", funcs["ls"](".", nothing, true))
    end
end

@testset "an ignored directory is never descended into" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "node_modules", "pkg"))
        write(joinpath(dir, ".gitignore"), "node_modules/\n")
        write(joinpath(dir, "node_modules", "pkg", "index.js"), "x\n")

        ctx = ignore_context(dir, dir)
        visited = String[]
        walk_filtered(ctx, dir) do root, _dirs, _files
            push!(visited, root)
            return true
        end
        @test length(visited) == 1
        @test !any(v -> occursin("node_modules", v), visited)

        # And with the flag on, the walk goes in.
        ctx_all = ignore_context(dir, dir; enabled = false)
        visited_all = String[]
        walk_filtered(ctx_all, dir) do root, _dirs, _files
            push!(visited_all, root)
            return true
        end
        @test any(v -> occursin("node_modules", v), visited_all)
    end
end

@testset "walk_filtered stops when the callback says so" begin
    mktempdir() do dir
        for name in ("a", "b", "c")
            mkpath(joinpath(dir, name))
            write(joinpath(dir, name, "f.txt"), "x\n")
        end
        ctx = ignore_context(dir, dir)
        seen = String[]
        completed = walk_filtered(ctx, dir) do root, _dirs, _files
            push!(seen, basename(root))
            return length(seen) < 2
        end
        @test !completed
        @test length(seen) == 2
    end
end

@testset ".git is skipped without any .gitignore present" begin
    mktempdir() do dir
        mkpath(joinpath(dir, ".git", "objects"))
        write(joinpath(dir, ".git", "objects", "blob"), "binaryish\n")
        write(joinpath(dir, "real.jl"), "content\n")

        funcs = search_funcs(dir)
        @test !occursin(".git", funcs["ls"](".", nothing, nothing))
        @test !occursin(".git", funcs["ls"](".", nothing, true))
        @test !occursin("blob", funcs["find"]("**/*", nothing, nothing, true))
        @test !occursin("binaryish", funcs["grep"]("binaryish", nothing, nothing, nothing, nothing, nothing, nothing, true))
    end
end

@testset "a symlinked directory is treated as a file" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "real"))
        write(joinpath(dir, "real", "inner.jl"), "x\n")
        symlink(joinpath(dir, "real"), joinpath(dir, "link"))
        # `link/` as a dir-only pattern must not match the symlink, which is how
        # git and `walkdir`'s default both see it.
        write(joinpath(dir, ".gitignore"), "link/\n")

        ctx = ignore_context(dir, dir)
        @test !is_ignored(ctx, "link", false)
        # And the walk does not follow it, so `inner.jl` is reported once.
        found = search_funcs(dir)["find"]("**/inner.jl", nothing, nothing, nothing)
        @test occursin("real/inner.jl", found)
        @test !occursin("link/inner.jl", found)
    end
end
