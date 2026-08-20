# LLMTools

`LLMTools` provides the tool suites used by the higher-level agent packages in this repo.

Current tool areas include:

- file editing and search
- PTY-backed terminal sessions
- Julia worker execution
- web fetch and search
- Subagent helpers

Semantic/code-search experiments are no longer exposed from `LLMTools`; that work moved to `LocalSearch.jl`.

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using LLMTools
```

## Tool Suites

```julia
using LLMTools

read_only = LLMTools.read_only_tools(pwd())
coding = LLMTools.coding_tools(pwd())
everything = LLMTools.all_tools(pwd(); workers = true)
```

## Ignored Files

`ls`, `find` and `grep` behave like `rg`: they skip whatever `.gitignore` excludes,
and a walk never descends into a directory named `.git`. A repository's build
output, dependency caches and packed git objects therefore stay out of the model's
context, and the three tools agree with each other and with what a developer sees.

Rules are collected from the base directory downwards, so a nested `.gitignore`
applies to its own subtree, a deeper file overrides a shallower one, and `!`
re-inclusions work. Each directory's `.git/info/exclude` is read as well, which
matters when the base directory holds several repositories. Nothing above the base
directory is consulted: that tree is outside what the tools are allowed to touch.

Each of the three takes a trailing `includeIgnored` argument to turn the filtering
off. The path a caller names is itself exempt, so a directory or file that the
rules exclude can still be reached by asking for it explicitly, exactly as
`rg dist/` searches `dist/`:

```julia
funcs = Dict(t.name => t.func for t in LLMTools.read_only_tools(pwd()))

funcs["find"]("**/*.jl")                                    # tracked files only
funcs["find"]("**/*.jl", nothing, nothing, true)            # ignored files too
funcs["grep"]("TODO", "build/generated.jl")                 # named file, ignored or not
funcs["ls"]("build")                                        # named dir, ignored or not
```

Two limits are worth knowing. The exemption covers the named path only: entries
*under* it are still filtered, so with `build/**` in a `.gitignore`,
`ls("build")` reports its contents as hidden. And `.git` is exempt on the same
terms as anything else, so a walk never enters it but `grep("token", ".git")`
does read it, which is also what `rg` does.

A `.gitignore` line that cannot be translated faithfully is inert, matching
nothing, the way git treats a malformed pattern. One unusable line costs that
line and not the whole tool.

## Terminal Tools

The PTY-backed terminal tools are created with:

```julia
tools = LLMTools.create_terminal_tools(pwd())
```

See:

- `examples/terminal_tools/README.md`
- `examples/terminal_tools/run_all.jl`
- `examples/terminal_tools/quick_smoke_test.jl`

## Web Tools

```julia
using LLMTools

tools = LLMTools.web_tools()
```

These provide the `web_fetch` and `web_search` tool wrappers used in tests and agent setups.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl LLMTools
```
