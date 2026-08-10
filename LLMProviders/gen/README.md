# Model registry generator

`LLMProviders/src/models_generated.json` is the checked model snapshot.
`LLMProviders/src/models_generated.jl` is its small loader. Do not edit either
file by hand. Put hand-maintained entries in `models_custom.jl`.

## Source of truth

The source is
[pi-mono](https://github.com/badlogic/pi-mono)'s generated JSON model catalog.
pi-mono gathers the live provider data. This package validates and converts that
snapshot without fetching provider APIs itself.

Current pi-mono no longer stores model literals in `models.generated.ts`. It
stores generated provider data outside Git. Create the JSON snapshot before this
package converts it.

## Refresh

```bash
# 1. Update pi-mono.
git -C ~/pi-mono pull --ff-only

# 2. Fetch provider catalogs and write .artifacts/model-catalog/models.json.
npm --prefix ~/pi-mono/packages/ai run generate-model-catalog

# 3. Validate and copy the canonical snapshot.
PI_MONO=~/pi-mono julia LLMProviders/gen/generate_models.jl

# 4. Test the package.
julia --project=. test/runtests.jl LLMProviders
```

The pi-mono task requires its supported Node version and network access. The
Julia conversion script uses Base only.

Source resolution order:

1. positional argument 1;
2. `$PI_MONO_MODELS_JSON`;
3. `$PI_MONO/.artifacts/model-catalog/models.json`;
4. `~/pi-mono/.artifacts/model-catalog/models.json`.

Positional argument 2 overrides the Julia loader path. The JSON path uses the
same stem with a `.json` extension.

Models whose `api` value Agentif cannot dispatch (see `DISPATCHABLE_APIS` in
`generate_models.jl`) are dropped at generation time; the run summary reports
the per-api drop counts.

The loader header records the source path, pi-mono revision, and generation
date. The catalog comes from live provider APIs. The same pi-mono commit can
therefore produce a different snapshot on a later date.

## Validation and output

- The parser rejects duplicate keys, trailing content, unknown model fields,
  missing required fields, model key or provider mismatches, and invalid cost
  shapes.
- It preserves numeric source tokens while it canonicalizes provider and model
  order.
- It preserves request-wide price tiers and thinking-level maps.
- It writes a compact JSON snapshot. A generic loader builds the registry during
  precompile. This avoids compiling one large Julia expression for every model.
- The loader registers the JSON file as an include dependency. A catalog change
  invalidates the package precompile cache.

## Known upstream data rules

- `openrouter/auto` and `openrouter/auto-beta` use `-1000000` input and output
  costs as dynamic-pricing sentinels.
- Price tiers apply to the full request when input plus cache-read plus
  cache-write tokens exceed the tier threshold. The highest matching threshold
  wins.

## Interaction with `models_custom.jl`

The generated registry loads first. The custom file loads second.

- `openai-codex` registers the ChatGPT-subscription models with custom zero
  prices.
- `google-gemini-cli` adds Cloud Code Assist models.

Current pi-mono already includes the frontier Anthropic models. They do not need
custom copies.
