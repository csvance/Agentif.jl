# Action Items: OpenAI/Codex parity fixes

## Context
- Repo: Agentif monorepo
- Worktree: /Users/jacob.quinn/.julia/dev/Agentif
- Branch: main

## Items

### [x] ITEM-001 (P0) Fix Codex websocket pooling safety
- Description: The Codex websocket pool currently keys connections only by websocket URL, even though the connection handshake carries authorization, account, and session state. That makes it possible to reuse a live websocket across unrelated credentials or sessions.
- Desired outcome: Codex websocket reuse is only possible when the reused socket is guaranteed to belong to the same logical Codex session/auth context; mismatched contexts must never share a socket.
- Affected files: `Agentif/src/providers/openai_codex.jl`, `Agentif/test/runtests.jl`
- Implementation notes:
  - Inspect the current pooling key and the headers that are bound at websocket-open time.
  - Change pooling/reuse semantics so sockets are isolated by the relevant Codex context, or disable reuse when that context is absent/unsafe.
  - Preserve the existing SSE fallback path, retry behavior, and websocket TTL semantics.
  - Add tests that prove same-context reuse remains allowed while cross-session/cross-auth reuse is blocked.
- Verification:
  - `julia --project=Agentif -e 'using Pkg; Pkg.test(; test_args=["Agentif"])'`
  - `julia --project=Agentif Agentif/test/runtests.jl`
- Assumptions:
  - Codex websocket authentication/session affinity is established during the websocket handshake, so reuse across differing headers is unsafe.
  - It is acceptable to narrow websocket reuse if needed to preserve correctness.
- Risks:
  - Over-correcting could disable a useful performance optimization for safe same-session reuse.
- Completion criteria:
  - Websocket reuse is isolated to safe Codex contexts.
  - Regression tests cover safe reuse and blocked cross-context reuse.
- Verification evidence:
  - `julia --project=Agentif -e 'using Pkg; Pkg.test()'`
  - Added websocket regression coverage for helper keying, same-session reuse, cross-session isolation, and no-session non-reuse.

### [x] ITEM-002 (P0) Restore Responses/Codex message normalization parity
- Description: The OpenAI Responses and Codex builders currently walk raw `AgentState` messages directly instead of using the normalization pipeline already used by the chat-completions path. That skips cross-model/provider handoff cleanup, missing-tool-result synthesis, and tool-call ID normalization that pi-mono relies on.
- Desired outcome: Responses and Codex requests are built from normalized history with the same invariants as the mature pi-mono path, including safe handoff behavior for tool calls, reasoning blocks, and missing tool results.
- Affected files: `Agentif/src/providers/openai_responses_adapter.jl`, `Agentif/src/providers/openai_codex.jl`, `Agentif/src/stream.jl`, `Agentif/test/runtests.jl`
- Implementation notes:
  - Reuse the existing `transform_messages` pipeline, or extract equivalent shared helpers, before constructing Responses/Codex payloads.
  - Preserve same-model reasoning/text signature roundtripping while downgrading incompatible reasoning/tool history for cross-model/provider handoffs.
  - Normalize pipe-separated tool IDs for Responses/Codex the same way the reference implementation does.
  - Ensure orphaned tool calls receive synthesized error tool results instead of being replayed as dangling calls.
  - Add regression tests for same-provider different-model handoff, cross-provider handoff, and tool-call-without-result history.
- Verification:
  - `julia --project=Agentif Agentif/test/runtests.jl`
  - `julia --project=Agentif -e 'using Pkg; Pkg.test()'`
- Assumptions:
  - The existing `transform_messages` semantics are the intended source of truth for cross-provider history normalization in this repo.
  - Preserving same-model opaque reasoning payloads remains desirable for prompt-cache continuity.
- Risks:
  - Too-aggressive normalization could reduce cache hits for safe same-model replay.
- Completion criteria:
  - Responses and Codex history builders no longer bypass normalization.
  - Regression tests cover normalized handoffs and dangling-tool-call repair.
- Verification evidence:
  - `julia --project=Agentif -e 'using Pkg; Pkg.test()'`
  - Added builder-level regression tests covering same-provider different-model tool-call replay, synthetic missing tool results, and cross-provider thinking downgrade behavior.

### [x] ITEM-003 (P1) Fix OpenAI request shaping and usage parity
- Description: Several OpenAI request/usage behaviors still drift from the reference implementation: direct Responses requests do not map `sessionId` to prompt-cache fields, GPT-5 direct Responses requests do not inject the “reasoning off” developer nudge when no reasoning is requested, cached input tokens are double-counted in usage, chat-completions usage cannot represent reasoning tokens, and incomplete Responses/Codex statuses currently emit error events.
- Desired outcome: OpenAI Responses, chat-completions, and Codex request/usage/status handling match the intended parity behavior for session caching, GPT-5 reasoning control, cached-token accounting, reasoning-token accounting, and incomplete-status handling.
- Affected files: `Agentif/src/stream.jl`, `Agentif/src/providers/openai_responses_adapter.jl`, `Agentif/src/providers/openai_completions_adapter.jl`, `Agentif/src/providers/openai_codex.jl`, `LLMProviders/src/providers/openai_completions.jl`, `Agentif/test/runtests.jl`, `LLMProviders/test/runtests.jl`
- Implementation notes:
  - Map `sessionId`/`session_id` for the direct Responses path to the correct prompt-cache fields and avoid leaking unsupported raw keys.
  - Add the GPT-5 “# Juice: 0 !important” behavior for direct Responses requests when reasoning is not explicitly enabled.
  - Subtract cached prompt/input tokens from billable input usage for Responses and chat-completions.
  - Add completions support for `completion_tokens_details.reasoning_tokens` and include those in output/total usage.
  - Treat `response.incomplete` as a normal length-stop path instead of emitting provider-error events.
  - Add regression tests for the above behaviors.
- Verification:
  - `julia --project=LLMProviders -e 'using Pkg; Pkg.test()'`
  - `julia --project=Agentif Agentif/test/runtests.jl`
- Assumptions:
  - The pi-mono request-shaping behavior is the desired parity target for these OpenAI paths.
  - Prompt-cache retention for direct Responses should remain configurable instead of hard-coded unless a narrower requirement emerges.
- Risks:
  - Request-shaping changes can subtly affect cache hits and token usage expectations, so tests need to assert payload structure precisely.
- Completion criteria:
  - Direct Responses maps session identifiers cleanly.
  - Usage accounting matches cached/reasoning token expectations.
  - Incomplete statuses no longer surface as hard errors.
- Verification evidence:
  - `julia --project=LLMProviders -e 'using Pkg; Pkg.test()'`
  - `julia --project=Agentif -e 'using Pkg; Pkg.test()'`
  - Added regression coverage for prompt-cache/session mapping, GPT-5 zero-juice request shaping, cached/reasoning token accounting, and incomplete-status handling for both Responses and Codex.

### [ ] ITEM-004 (P1) Harden Codex OAuth login and refresh behavior
- Description: The current Codex OAuth flow assumes the localhost callback server always binds successfully and does not provide a manual paste fallback. Refresh handling also rebuilds credentials from the refresh response without preserving the previous refresh token if the server omits a new one.
- Desired outcome: Codex OAuth remains usable when the callback server cannot be used, and refresh logic safely preserves a valid existing refresh token when the refresh response omits one.
- Affected files: `LLMOAuth/src/oauth.jl`, `LLMOAuth/test/runtests.jl`, `Agentif/ext/AgentifLLMOAuthExt/AgentifLLMOAuthExt.jl`
- Implementation notes:
  - Investigate whether the existing OAuth helper library exposes a clean manual-code path; otherwise implement a small, direct fallback for Codex login.
  - Support manual code parsing/entry when loopback listener setup fails or the callback does not arrive in time.
  - Preserve the prior refresh token when the refresh response does not include a replacement.
  - Add tests for JWT parsing, manual-code handling helpers, and refresh-token preservation.
- Verification:
  - `julia --project=LLMOAuth -e 'using Pkg; Pkg.test()'`
  - `julia --project=Agentif Agentif/test/runtests.jl`
- Assumptions:
  - Interactive login UX can remain terminal-based; no browser automation is needed.
  - Refresh responses may legally omit `refresh_token`, so preserving the prior token is the safe behavior.
- Risks:
  - Login-flow changes are easy to overcomplicate; keep the fallback minimal and local to Codex.
- Completion criteria:
  - Codex login has a non-loopback fallback path.
  - Refresh preserves the old token when no replacement is returned.
  - Tests cover the new fallback/preservation behavior.

### [ ] ITEM-005 (P2) Update Codex model parity and close remaining test gaps
- Description: The Codex model registry in this repo lags the local pi-mono reference and current internal expectations, and the existing tests do not lock in the newer Codex model variants or reasoning-effort clamp behavior.
- Desired outcome: The `openai-codex` registry includes the missing newer model IDs needed for parity, the reasoning-effort clamp covers the newer Codex family, and tests prevent regressions.
- Affected files: `LLMProviders/src/models_custom.jl`, `LLMProviders/test/runtests.jl`, `Agentif/test/runtests.jl`
- Implementation notes:
  - Compare the current `openai-codex` registry with the local pi-mono model set and add the missing entries needed for parity.
  - Extend the reasoning-effort clamp to cover the newer Codex family.
  - Add tests for the new registry entries and clamp behavior.
- Verification:
  - `julia --project=LLMProviders -e 'using Pkg; Pkg.test()'`
  - `julia --project=Agentif Agentif/test/runtests.jl`
- Assumptions:
  - The local `~/pi-mono` registry is the intended parity reference for Codex model IDs in this repo.
- Risks:
  - Adding model IDs without test coverage makes silent routing regressions likely.
- Completion criteria:
  - Missing Codex model entries are present.
  - Clamp behavior is tested for the newer models.

## Compaction Continuity Block

```text
* Take investigation/review findings and make a detailed, prioritized action item .md file; ensure each action item has enough detail (description, affected files, etc.) that a fresh context/engineer "taking on" the item would understand what needs to be done and where to go to get started and ideally how to verify that it's done
* Start working on the action-item list, for each item:
  * Thoroughly investigate the action item and work involved, state assumptions, do the work, including verification step
  * Work until verification succeeds (i.e. tests pass)
  * Mark the item done in the action item list
  * Commit the work involved for this action item
  * Continue with the same steps on the next action item
* When compacting, the itemizer instructions should be preserved *exactly* to ensure continuity
* The action-item document should very clearly state the repo/worktree where the work should be done
* Post-compaction, if there are unstaged edits in files relating to the current action item, you should assume they were your own edits and should continue directly w/ work without pausing to confirm
* No shortcuts or cutting corners while doing the action item work; each item should be done thoughtfully, carefully, with production-quality effort/work put into it; we're not trying to rush the work here at all and prefer quality, robustness, and thoroughness over "quick wins".
* No backwards compat or unnecessary shims should be included unless specifically requested
```
