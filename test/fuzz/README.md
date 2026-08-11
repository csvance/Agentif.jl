# Fuzz harnesses

Adversarial harnesses that complement the unit suites. They are **not** run by
`test/runtests.jl`: two need network and a paid API key, and all four are slow.
Run them by hand when touching tool plumbing, the PTY path, the agent loop, or
the Claw event pipeline.
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

## `claw_pipeline_fuzz.jl` — Claw's durable event pipeline (mostly offline)

`claw_fuzz.jl` covers only Claw's PTY capture. This one covers the runtime:
submit → dedup → claim → lane → retry/dead-letter → recovery → shutdown, plus the
model-facing db tools. Hostile content (invalid and truncated UTF-8, NUL bytes,
SQL/JSON metacharacters, 200KB payloads, 20k-line bodies, control characters) is
pushed through a concurrent submit storm with a fault-injecting handler swapped in
via the `RUN_EVENT_HANDLER_FN` seam, so scenarios 1-3 need no API key.

Asserts: no exception escapes `submit_event!`, dedup keys persist at most once,
nothing wedges in `pending`/`running`, crash-marked rows recover on reboot, and
db-tool output is valid UTF-8 and JSON-encodable.

Scenario 4 is **live** and skipped without `OPENROUTER_API_KEY` (read from
`~/league-easy/.env`): it drives the real `_run_event_handler!` → `Claw.evaluate`
→ `Agentif.evaluate` path with the same model `agent_fuzz.jl` uses, covering
system-prompt assembly, channel streaming, and session persistence end to end.

```bash
JULIA_NUM_THREADS=4 julia --project=. test/fuzz/claw_pipeline_fuzz.jl
```

Known pre-existing findings (present identically on `main` — compare before
treating any as a regression): `db_store`/`db_search` raise on NUL bytes and
invalid UTF-8 (reachable from a model, since JSON tool arguments can encode a NUL
escape), and live concurrent handlers can dead-letter events with
`SQLiteException("database is locked")`. The invalid-UTF-8 findings for persisted
payloads are artifacts of injecting raw bytes that no real source emits.
