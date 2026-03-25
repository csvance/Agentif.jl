# Claw

`Claw` is the event-driven assistant app layer built on top of `Agentif` and `LLMTools`.

It combines:

- SQLite-backed assistant/session state
- built-in management, scheduling, and storage tools
- event sources and handlers
- optional channel/platform extensions

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using Claw
```

## Quick Start

Initialize an assistant with the built-in `LLMToolsEventSource`:

```julia
using Claw

assistant = Claw.init!("claw.sqlite";
    provider = "openai",
    model_id = "gpt-4.1-mini",
    apikey = ENV["OPENAI_API_KEY"],
)
```

For a blocking app process, use:

```julia
Claw.run(; db_path = "claw.sqlite", provider = "openai", model_id = "gpt-4.1-mini", apikey = ENV["OPENAI_API_KEY"])
```

## Event Sources

Core exports include:

- `EventSource`, `Event`, `ChannelEvent`
- `EventType`, `EventHandler`
- `register_event_source!`, `register_event_handler!`, `register_channels!`
- `init!`, `run`, `start!`
- `ReplEventSource`, `ReplChannel`, `@a_str`

Examples live in `Claw/examples/`.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl Claw
```
