# LLMOAuth

`LLMOAuth` contains the interactive OAuth helpers used by the rest of the stack for Codex/OpenAI and Anthropic flows.

## Repo-Root Workflow

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then:

```julia
using LLMOAuth
```

## Available Helpers

- `anthropic_login()`
- `anthropic_access_token()`
- `codex_login()`
- `codex_credentials()`
- `codex_access_token()`
- `CodexCredentials`

## Quick Start

Fetch or refresh stored Codex credentials:

```julia
using LLMOAuth

creds = codex_credentials()
println(creds.account_id)
```

Fetch just the access token:

```julia
token = codex_access_token()
```

The helper stores auth state under `~/.agentif/`.

## Tests

From the repo root:

```bash
julia --project=. test/runtests.jl LLMOAuth
```
