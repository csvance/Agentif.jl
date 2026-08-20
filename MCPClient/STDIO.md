# Adding a stdio transport

MCP defines two standard transports. This note was the design for the second one,
written before the code so that adding it would be a new file rather than a
refactor. It is now implemented in `src/stdio_transport.jl` and tested in
`test/stdio.jl`, against a fake server that is a real child process
(`test/stdio_fakeserver.jl`). The text below is kept as written; the places where
the implementation went further than it are noted inline as *Implemented as*.

## What stdio is

The client spawns the server as a child process and speaks JSON-RPC over its
stdin and stdout. There is no HTTP, no session id and no URL. Framing is
newline-delimited JSON: exactly one JSON-RPC message per line, UTF-8, no embedded
newlines, terminated by `\n`. The child's stderr is not part of the protocol; it
is the server's log stream and belongs in the client's logs, not in the message
parser. Anything the client writes to the child's stdin that is not a valid
message line is a protocol violation, and so is anything non-JSON the child
writes to stdout, which is why a server that prints a banner on stdout is the
single most common cause of a broken stdio connection.

## What already fits

Everything above the transport is reusable as is:

* `src/jsonrpc.jl` builds and interprets messages and knows nothing about HTTP.
* `src/content.jl` parses tool results.
* `src/client.jl` performs the handshake, pagination, tool calls and the
  answering of server-initiated requests. It touches its transport through four
  functions only: `send_request!`, `send_notification!`, `close` and
  `set_handler!`, plus the optional `session_id` and `protocol_version!`, which a
  stdio transport can leave at their defaults of `nothing` and no-op.
* `run_with_deadline` and `Deadline` in `src/transport.jl` give the same
  per-request timeout semantics without any HTTP involvement.

So the work is one new file, `src/stdio_transport.jl`, and one line in
`src/MCPClient.jl` to include it.

## The shape of the type

```julia
mutable struct StdioTransport <: AbstractTransport
    process::Base.Process
    stdin::IO                       # child's stdin, we write
    stdout::IO                      # child's stdout, we read
    pending::Dict{Any,Deadline}     # request id -> waiter
    handler::Union{Nothing,Any}
    reader::Task
    stderr_task::Task
    closed::Bool
    write_lock::ReentrantLock
    lock::ReentrantLock
end
```

*Implemented as* the same shape with more bookkeeping: the `Cmd` itself, so every
error message can name the server that produced it; the child's stderr pipe and a
bounded tail of what it wrote; a `close_grace`; and a `failure` field, because a
stdio transport can be killed from the far side and `closed` alone cannot express
"the child died and nobody called close". The two task fields are
`Union{Nothing,Task}` since the tasks close over the object they live in.

The essential difference from HTTP is that the response to a request does not
arrive on the same call that sent it. HTTP hands back a body per POST, so
correlation is local to one function; stdio has a single shared byte stream, so a
reader task owns it and the pending table is what matches a response to the
request that is waiting for it.

## Construction

```julia
StdioTransport(command::Cmd; env=nothing, dir=nothing, timeout=DEFAULT_TIMEOUT)
```

* Spawn with `open(cmd, "r+")`, or `run(pipeline(cmd; stdin, stdout, stderr); wait=false)`
  when stderr is wanted separately, which it should be.
* Apply `env` by wrapping the command with `Cmd(cmd; env=..., dir=...)`. MCP
  servers are routinely configured entirely through environment variables, so
  this is not optional in practice.
* Start the reader task before returning, otherwise the child can fill the pipe
  buffer and block during the handshake.
* Start a second task that drains stderr line by line into `@debug`. Leaving
  stderr unread deadlocks a chatty server once the OS pipe buffer fills, and this
  failure looks exactly like a hung server.

*Implemented as* `open(pipeline(cmd; stderr=pipe), "r+")`. A freshly constructed
`PipeEndpoint` handed to `pipeline` is opened as the parent end and its child end
is closed here at spawn, which is what makes `eof` on stdout become true when the
child exits; an already-linked `Pipe` would leave this process holding a write end
of the child's own stdout, and then a dead child would be indistinguishable from
an idle one.

*Implemented as* `env` merged onto this process's environment rather than
replacing it, with `inherit_env=false` to opt out. A bare `Cmd(cmd; env=...)`
replaces the whole environment, and a server invoked through `npx` or `uvx`
without `PATH` or `HOME` fails in a way that has nothing to do with what the
caller was configuring.

*Implemented as* stderr going to `@debug` and to a bounded tail (50 lines by
default, see `stderr_tail`). Discarding it entirely is cheaper, but a server that
exits during startup explains itself only on stderr, and an `MCPTransportError`
that quotes the last thing the child said is the difference between a diagnosable
failure and a mystery.

## The reader task

```julia
while !eof(t.stdout)
    line = readline(t.stdout)
    isempty(strip(line)) && continue
    for msg in parse_payload(line)          # already handles single messages and batches
        if is_response(msg)
            deliver_to_pending!(t, msg)     # look up by id, deliver!, delete the entry
        else
            dispatch!(t, msg)               # same handler contract as HTTP
        end
    end
end
```

A line that fails to parse is logged and skipped rather than fatal: a server that
prints one stray line to stdout should degrade, not take the session down. When
the loop ends, the child has closed stdout, so every still-pending deadline gets
an `MCPTransportError` delivered to it; otherwise a caller waits out its full
timeout on a process that is already gone.

*Implemented as* above, plus two things the sketch leaves open. A response whose id
matches nothing pending is logged at debug and dropped, because the caller that
wanted it may simply have timed out already and neither that nor a server
answering a question nobody asked is worth ending a session over. And `is_open`
is specialised: a child can die without anyone calling `close`, so the recorded
failure is what makes the next request fail immediately with the exit code and the
log tail instead of waiting out a deadline.

## Sending

```julia
function send_request!(t::StdioTransport, message, id; timeout=t.timeout)
    d = Deadline()
    @lock t.lock (t.pending[id] = d)
    ...write the line...
    try
        return await_deadline(d, timeout, method)   # the take!-with-Timer half of run_with_deadline
    finally
        @lock t.lock delete!(t.pending, id)
    end
end
```

`await_deadline` is already factored out of `run_with_deadline` for exactly this
case: HTTP pairs one worker task with one request, while stdio registers a
`Deadline` under an id and waits on it, with the shared reader task delivering
the value. No change to existing code is needed.

Writing must hold `write_lock` for the whole `println(t.stdin, json); flush(t.stdin)`
pair, because two tasks interleaving halves of two messages produces two invalid
lines. Serialise with `JSON.json`, which never emits a raw newline, and assert
the result contains none before writing.

`send_notification!` writes the same way and returns immediately, with no pending
entry, since nothing will ever be delivered for it.

*Implemented as* one lock covering both the aliveness check and the registration
of the waiter, the same lock the reader empties `pending` under. Checking first
and registering afterwards loses the race against a child that dies in between,
and the caller then waits out its whole timeout for a response that can never
come.

*Implemented as* a write on the caller's own task, with no deadline of its own. A
write abandoned halfway leaves a partial line and corrupts every message after it,
which is worse than blocking against a child that has stopped reading its stdin;
MCP messages are far below a pipe buffer, so only an already wedged child can
block here.

## Shutdown

The spec's ordering matters, because a server that is killed mid-write leaves a
half-written line and, worse, may leave its own side effects half-done:

1. Close the child's stdin. That is the documented signal to exit.
2. Wait for the process for a short grace period, a second or two.
3. `kill(process)` (SIGTERM) if it is still running, wait again briefly.
4. `kill(process, Base.SIGKILL)` as the last resort.

Then fail every remaining pending deadline, wait on the reader and stderr tasks,
and set `closed`. As with HTTP, `close` must be safe to call twice, and it must
not throw when the process is already dead.

*Implemented as* above, with `closed` set first so the call is idempotent from the
moment it starts, and with the read ends of stdout and stderr closed before
waiting on the tasks: a grandchild that inherited the pipes keeps them open, and
then the child exiting is not enough to end the readers. Neither `wait(::Process)`
nor `wait(::Task)` takes a deadline, so both waits poll; `close` must not be able
to hang.

## What does not carry over

* No session id: `session_id` stays `nothing`.
* No `MCP-Protocol-Version` header, so `protocol_version!` stays a no-op.
* No SSE and no resumability; there is exactly one stream and it is ordered.
* Server-initiated requests are answered by writing a response line to the same
  stdin, which is simpler than HTTP's "POST the response back". The client layer
  already routes these through `send_notification!` (any message that expects no
  reply), so no change is needed there.

## Testing it offline

The HTTP tests stand up a fake server in-process; the stdio equivalent is a fake
server that is a Julia script run by `julia --startup-file=no fake_server.jl`,
reading lines from stdin and writing responses to stdout. Worth covering beyond
the parallel of the HTTP cases: a server that prints noise to stdout, a server
that writes a large amount to stderr and never reads stdin, and a server that
exits mid-request, which must surface as `MCPTransportError` on every pending
call rather than as a timeout.
