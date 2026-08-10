# Fuzz harnesses

Adversarial harnesses that complement the unit suites. They are **not** run by
`test/runtests.jl`: two need network and a paid API key, and all three are slow.
Run them by hand when touching tool plumbing, the PTY path, or the agent loop.
Bugs they find should become regression tests in the normal suites (as the
existing `LLMTools/test/hostile_output_test.jl`, `LLMTools/test/optional_args_test.jl`,
and `Claw/test/pty_output_test.jl` did).

Each prints a `FINDINGS` block and exits 0; read the block, don't trust the
exit code.

## `tool_fuzz.jl` — tools vs. hostile input (offline, free)

Drives the LLMTools tools through the exact path the agent uses (JSON argument
string → `parse_tool_arguments` → `invoke_parsed_tool`) with binary payloads,
invalid and truncated UTF-8, NUL bytes, ANSI escapes, 200KB lines, 50k-line
output, path-traversal attempts, malformed argument JSON, and session-limit
pressure. Asserts every result is a valid-UTF-8, JSON-encodable String and that
no call hangs.

```bash
JULIA_NUM_THREADS=4 julia --project=. test/fuzz/tool_fuzz.jl
```

## `claw_fuzz.jl` — Claw's PTY capture path (offline, free)

Claw has its own capture machinery (`_start_pty_capture`, `_truncate_pty_output`)
separate from LLMTools. Checks that the reader observes EOF on its own, and that
every path out of the raw buffer to the model or SQLite yields valid UTF-8. The
raw buffer itself deliberately holds raw bytes.

```bash
JULIA_NUM_THREADS=4 julia --project=. test/fuzz/claw_fuzz.jl
```

## `agent_fuzz.jl` — end-to-end agent loops (network, costs money)

Runs real `evaluate()` loops against OpenRouter, hunting for exceptions escaping
the loop, hangs, non-encodable transcripts, and provider-side 4xx caused by data
we generated. Covers hostile tool output fed back to the provider, prompt-
injection-shaped input, malformed/nonexistent tool calls, degenerate prompts, and
session pressure.

Reads `OPENROUTER_API_KEY` from `~/league-easy/.env`. Defaults to
`deepseek/deepseek-v4-flash-0731` (cheapest usable tier); override with
`FUZZ_MODEL`. A full run is a few cents.

```bash
JULIA_NUM_THREADS=4 julia --project=. test/fuzz/agent_fuzz.jl
FUZZ_MODEL=deepseek/deepseek-v4-flash julia --project=. test/fuzz/agent_fuzz.jl
```
