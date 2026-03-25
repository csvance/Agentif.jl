# Juco

**WARNING: JUCO IS NOT CURRENTLY USABLE AS A REAL PACKAGE SURFACE.**

**WARNING: THIS PACKAGE IS ONLY A PLACEHOLDER AND IS EXPECTED TO BE REWRITTEN SOON.**

`Juco` currently exists as a stubbed-out package shell around `Agentif` + `LLMTools`.

## Current State

- The package exports `coding_agent` and `default_coding_prompt`.
- There is no dedicated test suite yet.
- The current implementation should be treated as temporary scaffolding, not a supported workflow.

## If You Still Want To Inspect It

From the repo root:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
using Juco
```

But treat the current API as unstable and likely to change substantially.
