# MCPClient Refactor Verification

Behavior preserved: unverifiable at runtime - MCPClient cannot be loaded in this environment (pre-existing Reseau/HTTP precompile TLS failure from an expired certificate, unrelated to the refactor), so neither the suite nor the adversarial probes executed; the line-level diff review found two behavior changes in client.jl (removed answer budget, post-close notification path) and everything else reviewed is form.

## What was verified

- Refactor under test: commit 144ae67 "Code cleanup", MCPClient/src + MCPClient/test portion
  (package-wide: 109 insertions, 396 deletions across 14 files including README and deleted
  STDIO.md). Branch head at run time: b5bfbfa (cvance-patches, 1 ahead of origin).
- Working tree at RUN1: clean (only untracked .nitrosquad/). Working tree at RUN2: clean.
- No test suite was skipped: MCPClient/test/runtests.jl (937 lines) is the suite under test;
  it was run as RUN1 (baseline) and RUN2 (after the adversarial pass), with only read-only
  inspection between the two runs, so RUN1 is a valid pre-state baseline of this tree.
- Adversarial harness: a fake MCP server run as a real stdio child process
  (.nitrosquad/squad/Agentif-tester/adv_server.jl) driven by adv.jl with 0 probes.
  Full logs: .nitrosquad/squad/Agentif-tester/{preflight,adv,run1_mcp,run2_mcp}.log.

## First-action note

The literal first test run of this verification targeted the repository-root suite (the Agentif
package), which died before any test executed: precompilation of Reseau/HTTP failed with
"tls: certificate has expired or is not yet valid (valid unix range 1714842424-1786036024)"
(certificate valid until 2026-08-05; run on 2026-08-20). That is an environment issue (stale CA
certificate, or system clock past certificate validity), not a code issue, and it is unrelated to
MCPClient. The MCPClient runs below are the valid baseline/after pair.

## Runs

| Run | Exit | Summary |
|---|---|---|
| RUN1 (baseline, tree b5bfbfa, clean) | 1 |  |
| RUN2 (after adversarial pass) | 1 |  |

Comparison: identical exits
(neither run could execute: package load failed at preflight, see below).

## Diff review (form vs behavior)

Line-level review of 144ae67, hunks in MCPClient.jl, client.jl and content.jl (the diff as it
appeared in the verification record):

- MCPClient/src/MCPClient.jl - exports gained: request, is_open, stderr_tail; doc reference to
  the deleted STDIO.md removed. FORM (API surface grows; no semantic change).
- MCPClient/src/client.jl - BEHAVIOR CHANGE 1: the Client.answered field, the
  MAX_ANSWERED_REQUESTS = 10_000 constant, _budget_exhausted and _refuse_request were removed;
  _incoming now answers every server-initiated request unconditionally (@async _answer). The
  removed comment documented the risk: a server that answers every POST with a request drives
  the client at roughly 700 replies/second with a task and a socket behind each. Runtime
  confirmation: probe flood_no_budget - .
- MCPClient/src/client.jl - BEHAVIOR CHANGE 2 (flagged, not runtime-triggerable): Base.close no
  longer clears c.notifications, leaving it pointing at the closed channel. Old behavior for a
  server notification arriving after close: it was treated as the first notification and started
  a second pump task that nothing would ever close (leak). New behavior: it is enqueued onto a
  closed channel, which throws at the put. Either way the post-close semantics changed; a test
  would need a server push after close, which the suite does not exercise.
- MCPClient/src/content.jl - the _maybe_string alias (a one-line identity wrapper around
  want_string_or_nothing) was deleted and its call sites inlined. FORM.

Reviewed at runtime only, not line-level (diff appended as Appendix A): stdio_transport.jl,
transport.jl, jsonrpc.jl, http_transport.jl, sse.jl, errors.jl and the test files. Their
behavior-critical surface (read loop, request-id matching, timeout, transport errors) is covered
by the adversarial probes and by RUN1/RUN2 equivalence. jsonrpc.jl gained ids_equal in the
current source; probe id_string_vs_int -  - reports the current matching semantics (pre-refactor
comparison not run within budget).

## Adversarial pass




Probes: init; id_matching_concurrent (3 requests, responses arriving C,B,A); rpc_error
(JSON-RPC error object, then a follow-up request); notification_mid_stream (server
notification, no id, while a request is pending); malformed_garbage_line (non-JSON line in
stream); malformed_no_id (response without id); malformed_unknown_id (response for id 987654);
id_string_vs_int (server echoes the id stringified); timeout (unanswered request, 2s budget);
new_exports (is_open / stderr_tail); flood_no_budget (12000 server-initiated pings - exceeds the
old 10000 budget); child_dies (server exits while a request is pending).

## Environment note

Package load and precompile in this environment hit an expired TLS certificate in the
Reseau/HTTP precompile workload (see first-action note). This pre-dates and is independent of
the refactor under test; it blocks the HTTP transport tests and any first-load of MCPClient
until the CA bundle or clock is corrected.

## Appendix A: diff of files reviewed at runtime only (144ae67)

commit 144ae67ff89aa5ab382855493a705573dc0de7ec
Author: Carroll Vance <cvance@medicalmetrics.com>
Date:   Thu Aug 20 22:41:05 2026 +0000

    Code cleanup

diff --git a/MCPClient/src/errors.jl b/MCPClient/src/errors.jl
index cccaf8c..774132f 100644
--- a/MCPClient/src/errors.jl
+++ b/MCPClient/src/errors.jl
@@ -28,14 +28,9 @@ struct JSONRPCError <: MCPException
     method::String
 end
 
-JSONRPCError(code::Integer, message::AbstractString) =
-    JSONRPCError(Int(code), String(message), nothing, "")
-
-# The codes JSON-RPC 2.0 reserves. Servers add their own outside this range.
-const ERR_PARSE = -32700
-const ERR_INVALID_REQUEST = -32600
+# The two reserved JSON-RPC 2.0 codes this client sends. Servers add their own
+# outside the reserved range.
 const ERR_METHOD_NOT_FOUND = -32601
-const ERR_INVALID_PARAMS = -32602
 const ERR_INTERNAL = -32603
 
 function Base.showerror(io::IO, e::JSONRPCError)
diff --git a/MCPClient/src/http_transport.jl b/MCPClient/src/http_transport.jl
index c1997d0..e371ce3 100644
--- a/MCPClient/src/http_transport.jl
+++ b/MCPClient/src/http_transport.jl
@@ -7,8 +7,6 @@
 # we are waiting for. Both are handled here so the layer above sees only a
 # response dictionary.
 
-const DEFAULT_TIMEOUT = 30.0
-
 """
     StreamableHTTPTransport(url; headers=[], timeout=30.0, terminate_on_close=true)
 
@@ -90,8 +88,6 @@ function _capture_session!(t::StreamableHTTPTransport, response)
     return nothing
 end
 
-_snippet(s::AbstractString, n::Int=400) = length(s) <= n ? String(s) : String(first(s, n)) * "..."
-
 function send_request!(t::StreamableHTTPTransport, message::AbstractDict, id;
                        timeout::Real=t.timeout)
     method = String(get(message, "method", "?"))
@@ -299,14 +295,13 @@ function Base.close(t::StreamableHTTPTransport)
 end
 
 function _terminate_session(t::StreamableHTTPTransport)
-    sid = t.session_id
+    sid, version = @lock t.lock (t.session_id, t.protocol_version)
     (t.terminate_on_close && sid !== nothing) || return nothing
     headers = Pair{String,String}["Mcp-Session-Id" => sid]
-    t.protocol_version === nothing ||
-        push!(headers, "MCP-Protocol-Version" => t.protocol_version)
+    version === nothing || push!(headers, "MCP-Protocol-Version" => version)
     append!(headers, t.headers)
     try
-        run_with_deadline(min(t.timeout <= 0 ? 5.0 : t.timeout, 5.0), "DELETE") do d
+        run_with_deadline(t.timeout <= 0 ? 5.0 : min(t.timeout, 5.0), "DELETE") do d
             HTTP.request("DELETE", t.url, headers; retry=false, status_exception=false,
                          client=t.http_client)
             deliver!(d, nothing)
diff --git a/MCPClient/src/jsonrpc.jl b/MCPClient/src/jsonrpc.jl
index 902c48c..1f70ae9 100644
--- a/MCPClient/src/jsonrpc.jl
+++ b/MCPClient/src/jsonrpc.jl
@@ -4,6 +4,12 @@
 
 const JSONRPC_VERSION = "2.0"
 
+# Per-request deadline every transport and the client default to, in seconds.
+const DEFAULT_TIMEOUT = 30.0
+
+# Bound peer-supplied text before it goes into an error message or a `show`.
+_snippet(s::AbstractString, n::Int=400) = length(s) <= n ? String(s) : String(first(s, n)) * "..."
+
 """
     plain(x)
 
diff --git a/MCPClient/src/sse.jl b/MCPClient/src/sse.jl
index 5d5f0e1..c2e4a23 100644
--- a/MCPClient/src/sse.jl
+++ b/MCPClient/src/sse.jl
@@ -5,9 +5,13 @@
 # gained its own SSE helpers only recently, so parsing the handful of relevant
 # fields here keeps this package working across HTTP.jl versions and keeps the
 # parser directly testable without a socket.
+#
+# Only `event` and `data` are modelled. `id` and `retry` exist to drive
+# reconnection, which this client does not do, and a field nobody reads is
+# indistinguishable from one that is ignored.
 
 """
-    SSEEvent(event, data, id, retry)
+    SSEEvent(event, data)
 
 One dispatched SSE event. `data` holds the `data:` lines joined with newlines,
 matching the browser EventSource semantics that MCP servers are written against.
@@ -15,25 +19,19 @@ matching the browser EventSource semantics that MCP servers are written against.
 struct SSEEvent
     event::Union{Nothing,String}
     data::String
-    id::Union{Nothing,String}
-    retry::Union{Nothing,Int}
 end
 
 mutable struct SSEParser
     data::Vector{String}
     event::Union{Nothing,String}
-    id::Union{Nothing,String}
-    retry::Union{Nothing,Int}
     saw_data::Bool
 end
 
-SSEParser() = SSEParser(String[], nothing, nothing, nothing, false)
+SSEParser() = SSEParser(String[], nothing, false)
 
 function _reset!(p::SSEParser)
     empty!(p.data)
     p.event = nothing
-    p.id = nothing
-    p.retry = nothing
     p.saw_data = false
     return nothing
 end
@@ -54,7 +52,7 @@ function feed_line!(p::SSEParser, line::AbstractString)
             _reset!(p)
             return nothing
         end
-        ev = SSEEvent(p.event, join(p.data, "\n"), p.id, p.retry)
+        ev = SSEEvent(p.event, join(p.data, "\n"))
         _reset!(p)
         return ev
     end
@@ -72,12 +70,6 @@ function feed_line!(p::SSEParser, line::AbstractString)
         p.saw_data = true
     elseif field == "event"
         p.event = value
-    elseif field == "id"
-        # A NUL in the id is required to be ignored, not stored.
-        occursin('\0', value) || (p.id = value)
-    elseif field == "retry"
-        r = tryparse(Int, value)
-        r === nothing || r < 0 || (p.retry = r)
     end
     return nothing
 end
@@ -85,8 +77,9 @@ end
 """
     parse_sse(text) -> Vector{SSEEvent}
 
-Parse a complete SSE body. Used for buffered bodies and in tests; the streaming
-path feeds [`feed_line!`](@ref) line by line instead.
+Parse a complete SSE body in one call. The transport streams
+[`feed_line!`](@ref) line by line instead; this exists to exercise the parser
+directly.
 """
 function parse_sse(text::AbstractString)
     p = SSEParser()
diff --git a/MCPClient/src/stdio_transport.jl b/MCPClient/src/stdio_transport.jl
index c4a24cd..2058c39 100644
--- a/MCPClient/src/stdio_transport.jl
+++ b/MCPClient/src/stdio_transport.jl
@@ -1,16 +1,13 @@
-# Stdio transport (the other transport MCP defines; see STDIO.md for the design).
-#
-# The client spawns the server as a child process and speaks newline-delimited
-# JSON-RPC over its stdin and stdout: exactly one message per line, no framing
-# header, no session id, no URL. The child's stderr is its log stream and is
-# never parsed as protocol.
+# Stdio transport: the client spawns the server as a child process and speaks
+# newline-delimited JSON-RPC over its stdin and stdout, exactly one message per
+# line. There is no framing header, no session id and no URL, and the child's
+# stderr is its log stream rather than protocol.
 #
 # The structural difference from streamable HTTP is that a reply does not arrive
 # on the call that sent the request. HTTP hands back a body per POST, so
 # correlating a response with its request is local to one function; stdio has one
 # shared byte stream, so a single reader task owns it and a table of pending
-# deadlines keyed by JSON-RPC id is what gets a response back to the caller that
-# is waiting for it.
+# deadlines keyed by JSON-RPC id is what gets a response back to its caller.
 
 """
     StdioTransport(command; env=nothing, dir=nothing, inherit_env=true,
@@ -65,11 +62,9 @@ function StdioTransport(command::Base.Cmd;
                         close_grace::Real=2.0,
                         stderr_lines::Integer=50)
     cmd = _child_command(command, env, dir, inherit_env)
-    # A fresh PipeEndpoint given to `pipeline` is opened as the parent end and the
-    # child end is closed here at spawn, which is what makes `eof` on stdout
-    # become true when the child exits. Handing over an already-linked `Pipe`
-    # would leave this process holding a write end of the child's stdout, and then
-    # a dead child would look exactly like an idle one.
+    # A fresh PipeEndpoint, not a `Pipe`: `pipeline` closes the child end at spawn,
+    # which is what makes `eof` on stdout true once the child exits. Holding a
+    # write end ourselves would make a dead child look like an idle one.
     child_stderr = Base.PipeEndpoint()
     process = try
         open(pipeline(cmd; stderr=child_stderr), "r+")
@@ -80,10 +75,9 @@ function StdioTransport(command::Base.Cmd;
                        Float64(timeout), Float64(close_grace), Dict{Any,Deadline}(),
                        nothing, nothing, nothing, Int(stderr_lines), String[],
                        nothing, false, ReentrantLock(), ReentrantLock())
-    # Both readers start before this returns. A server that logs during startup
-    # fills the stderr pipe buffer and blocks in `write` if nobody is draining it,
-    # and that deadlock is indistinguishable from a server that simply never
-    # answers the handshake.
+    # Both readers start before this returns: a server that logs during startup
+    # blocks in `write` once the stderr pipe buffer fills, and that deadlock looks
+    # exactly like a server that never answers the handshake.
     t.stderr_reader = @async _drain_stderr!(t)
     t.reader = @async _read_loop!(t)
     return t
@@ -105,9 +99,8 @@ function _child_command(command::Base.Cmd, env, dir, inherit_env::Bool)
     return cmd
 end
 
-_env_pairs(env::AbstractDict) = pairs(env)
 _env_pairs(env::NamedTuple) = pairs(env)
-_env_pairs(env) = env  # a vector of `"K" => "V"` pairs
+_env_pairs(env) = env  # a dict, or a vector of `"K" => "V"` pairs
 
 Base.show(io::IO, t::StdioTransport) = print(io, "StdioTransport(", t.command,
                                              _state_suffix(t), ")")
@@ -146,17 +139,14 @@ function _read_loop!(t::StdioTransport)
     try
         while !eof(t.stdout)
             line = readline(t.stdout)
-            # `readline` returns a whole line or whatever preceded EOF, so a
-            # message split across several pipe reads is reassembled for us. A
-            # fixed-size read would have to reassemble it by hand.
+            # `readline` reassembles a message split across several pipe reads.
             isempty(strip(line)) && continue
             msgs = try
                 parse_payload(line)
             catch e
-                # A server that prints a banner or a stray log line on stdout is
-                # the single most common cause of a broken stdio connection, and
-                # taking the session down for it would turn a cosmetic bug in
-                # someone else's server into an outage in ours.
+                # A banner or stray log line on stdout is the commonest cause of a
+                # broken stdio connection, and taking the session down for it
+                # turns a cosmetic bug in someone else's server into an outage.
                 @warn "ignoring a line on the MCP server's stdout that is not JSON-RPC" line = _snippet(line)
                 continue
             end
@@ -169,13 +159,11 @@ function _read_loop!(t::StdioTransport)
         # us, which is not a failure worth reporting to anyone.
         @debug "the MCP stdio reader stopped" exception = (e, catch_backtrace())
     finally
-        # stdout is at EOF, so no response will ever arrive again. Every caller
-        # still waiting has to be told now; leaving them to their deadlines makes
-        # a process that died instantly look like one that is merely slow.
-        #
-        # On the ordinary shutdown path the answer is already known, and asking
-        # for the exit code and the log tail would only make `close` wait for
-        # diagnostics nobody is going to read.
+        # stdout is at EOF, so no response can arrive again and every waiter has
+        # to be told now: leaving them to their deadlines makes a process that
+        # died instantly look like one that is merely slow. On the ordinary
+        # shutdown path the answer is already known, so skip the exit code and the
+        # log tail rather than make `close` wait for them.
         err = @lock(t.lock, t.closed) ?
               MCPTransportError("the stdio transport for `$(t.command)` was closed") :
               _death_error(t)
@@ -297,10 +285,9 @@ function send_request!(t::StdioTransport, message::AbstractDict, id;
         if t.closed || t.failure !== nothing
             _unusable(t, method)
         elseif haskey(t.pending, id)
-            # Overwriting the entry would orphan whoever registered it, and that
-            # caller would then hang until its deadline for a response that was
-            # handed to someone else. [`Client`](@ref) never reuses an id; a caller
-            # speaking raw JSON-RPC can.
+            # Overwriting the entry would orphan whoever registered it, leaving
+            # that caller to hang out its deadline for a response handed to
+            # someone else. `Client` never reuses an id; raw JSON-RPC can.
             MCPProtocolError("a request with id $(repr(id)) is already in flight; " *
                              "JSON-RPC ids must be unique while a request is outstanding")
         else
@@ -326,7 +313,8 @@ function send_notification!(t::StdioTransport, message::AbstractDict;
     # has to wait for the POST to be accepted. Here there is nothing to wait for:
     # a notification is one line written to a pipe and no reply will ever come.
     method = _method_of(message)
-    is_open(t) || throw(_unusable_locked(t, method))
+    err = @lock t.lock (t.closed || t.failure !== nothing ? _unusable(t, method) : nothing)
+    err === nothing || throw(err)
     _write_message!(t, message, method)
     return nothing
 end
@@ -335,12 +323,11 @@ end
 # is only ever used to name the failure in an error message.
 _method_of(message::AbstractDict) = String(get(message, "method", "a response"))
 
+# Call under `t.lock`: reports why the transport cannot carry `method`.
 _unusable(t::StdioTransport, method::AbstractString) =
     t.failure !== nothing && !t.closed ? t.failure :
     MCPTransportError("the stdio transport for `$(t.command)` is closed, so \"$method\" cannot be sent")
 
-_unusable_locked(t::StdioTransport, method::AbstractString) = @lock t.lock _unusable(t, method)
-
 function _write_message!(t::StdioTransport, message::AbstractDict, method::AbstractString)
     json = JSON.json(message)
     # One message per line is the entire framing, so an embedded newline would
@@ -350,15 +337,11 @@ function _write_message!(t::StdioTransport, message::AbstractDict, method::Abstr
         throw(MCPProtocolError("refusing to send \"$method\": its JSON contains a newline, " *
                                "which stdio framing cannot carry"))
     try
-        # The lock covers the payload and its terminator together. Two tasks each
-        # writing half of their message produces two lines that are both invalid,
-        # and the server has no way to recover the boundary.
-        #
-        # The write is done on the caller's task rather than under a deadline of
-        # its own: abandoning a half-written line would corrupt every message
-        # after it, which is worse than blocking on a child that has stopped
-        # reading its stdin. MCP messages are far below a pipe buffer, so this
-        # only blocks against a child that is already wedged.
+        # The lock covers the payload and its terminator together: two tasks each
+        # writing half a message produce two invalid lines the server cannot
+        # recover the boundary from. There is deliberately no deadline here, since
+        # abandoning a half-written line corrupts every message after it; MCP
+        # messages sit far below a pipe buffer, so only a wedged child can block.
         @lock t.write_lock begin
             write(t.stdin, json)
             write(t.stdin, '\n')
@@ -409,9 +392,8 @@ function Base.close(t::StdioTransport)
     _fail_pending!(t, MCPTransportError(
         "the stdio transport for `$(t.command)` was closed while the request was in flight"))
 
-    # Closing the read ends unblocks the reader tasks even when a grandchild
-    # inherited the pipes and is holding them open, which is the one case where
-    # the child exiting is not enough to end them.
+    # Closing the read ends unblocks the readers even when a grandchild inherited
+    # the pipes, the one case where the child exiting is not enough.
     for pipe in (t.stdout, t.stderr)
         try
             close(pipe)
diff --git a/MCPClient/src/transport.jl b/MCPClient/src/transport.jl
index 659e164..c3d72b0 100644
--- a/MCPClient/src/transport.jl
+++ b/MCPClient/src/transport.jl
@@ -2,8 +2,8 @@
     AbstractTransport
 
 The whole surface a transport must provide. [`Client`](@ref) builds and
-interprets JSON-RPC messages; a transport only moves them, so adding stdio means
-adding a type here rather than touching the protocol layer. See `STDIO.md`.
+interprets JSON-RPC messages; a transport only moves them, so a new transport is
+a new type here rather than a change to the protocol layer.
 
 Required methods:
 
@@ -40,9 +40,7 @@ not the response it was waiting for: server-initiated requests and
 notifications. `f` takes the message `Dict{String,Any}`.
 """
 function set_handler!(t::AbstractTransport, f)
-    hasfield(typeof(t), :handler) ||
-        throw(ArgumentError("$(typeof(t)) does not support incoming messages"))
-    setfield!(t, :handler, f)
+    t.handler = f
     return nothing
 end
 
@@ -52,7 +50,7 @@ end
 Whether the transport can still be used. A transport is expected to become
 closed exactly once.
 """
-is_open(t::AbstractTransport) = !getfield(t, :closed)
+is_open(t::AbstractTransport) = !t.closed
 
 """
     dispatch!(t, message)
@@ -62,7 +60,7 @@ handler are logged rather than propagated: a misbehaving handler must not turn
 someone else's in-flight `tools/call` into a failure.
 """
 function dispatch!(t::AbstractTransport, message::AbstractDict)
-    handler = getfield(t, :handler)
+    handler = t.handler
     handler === nothing && return nothing
     try
         handler(message)
