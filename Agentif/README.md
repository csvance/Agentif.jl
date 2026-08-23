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

## Skills

Skills follow the [Agent Skills](https://agentskills.io) standard the way Claude Code
implements it: a model sees a small catalog, loads a skill's instructions on demand, and reads
whatever else the skill bundles with its normal file tools.

### Bundle structure

A skill is a **directory** containing `SKILL.md` (YAML frontmatter + markdown instructions) plus
anything else: helper scripts, reference docs, templates, or per-environment sub-skill notes.
`SKILL.md` refers to those files with paths relative to the skill directory — the standard's
"relative paths from the skill root". `scripts/`, `references/`, and `assets/` are the standard's
recommended conventions, not a closed set; the advice to keep `SKILL.md` under ~500 lines and
references one level deep is authoring guidance, not enforced.

### Discovery

`discover_skills(paths)` scans each base path **one level deep**: a skill is a directory
holding a `SKILL.md` directly under the base path, in `readdir`-sorted order. Discovery is
deliberately flat (the Claude Code layout): a *subdirectory* that also contains a `SKILL.md`
is not a skill — it is a bundled file in the tree, reached by the model's file tools like any
other resource a SKILL.md might reference. Recursing would turn such directories into
name-claiming skills that shadow their neighbors, which is why the walk stays one level.

- **Name collisions** resolve first-found-wins across the whole `paths` list, with a warning —
  the order of the base paths IS the precedence order. `default_skill_dirs` lists the project
  directory before the user directory, which is what "project skills override user skills" means
  in code.
- **Invalid bundles** (unparseable frontmatter, missing fields, invalid name) warn and are
  skipped; one bad bundle never takes its neighbors down.
- **Name rules**, per the standard: 1–64 characters of `[a-z0-9-]`, no leading/trailing (and no
  consecutive) hyphens, and the name **must match the directory's basename**. That rule is kept
  strict: the format spec requires the match (pi deliberately deviates for shared skill
  directories; Claude Code treats the directory as the identity and the frontmatter name as a
  display label). Relaxing to warn-and-load is a noted follow-up, not current behavior.

### Serving

- The `<available_skills>` catalog appended to the system prompt lists each skill's name,
  description, and `<location>` (the SKILL.md path) — `include_location` defaults to `true`, per
  the standard's "otherwise, include it". The directory containing `<location>` is where the
  model resolves every relative reference in the skill body.
- `skill_loader(name)` (from `create_skill_loader_tool`) returns the full SKILL.md. Results are
  truncated at 1 MB (`MAX_TOOL_RESULT_BYTES`) with a read-tool hint.
- Bundled resources are **not** served by the loader. The model reads them with its own file
  tools at the absolute path — skill directory + the relative reference — the same model Claude
  Code uses. A harness whose file tools are contained to a working directory must make the skill
  directories reachable (extend the tool roots, or allowlist the skill directories, which is the
  standard's own recommendation for permission-gated file access).
- There is no `${CLAUDE_SKILL_DIR}`-style path substitution: that is a Claude Code extension,
  not part of the standard.

## Related Packages

- `LLMTools` for ready-made tool suites.
- `LLMProviders` for model metadata and provider-specific request/response types.
- `LLMOAuth` for Codex/OpenAI and Anthropic OAuth helpers.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Agentif
```
