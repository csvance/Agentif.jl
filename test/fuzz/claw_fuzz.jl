# Layer 3: Claw's own PTY capture path (separate machinery from LLMTools).
# Exercises _start_pty_capture / _take_pty_capture! with hostile output and
# lifecycle edges. No API cost.

using Claw, LLMTools, JSON

const FINDINGS = String[]
finding(s) = (push!(FINDINGS, s); println("  !! FINDING: ", s))

const PtySessions = LLMTools.PtySessions

function capture(cmd::String; release = nothing, wait_s = 8.0)
    session = PtySessions.PtySession(`bash -lc $cmd`; dir = mktempdir())
    buf, lock_, stop, task = Claw._start_pty_capture(session; release = release)
    finished = timedwait(() -> istaskdone(task), wait_s; pollint = 0.02) !== :timed_out
    stop[] = true
    timedwait(() -> istaskdone(task), 5.0; pollint = 0.02)
    out = Claw._take_pty_capture!(buf, lock_)
    try
        close(session; force = true)
    catch
    end
    return (out = out, finished = finished, task = task)
end

function check(label, r)
    if !r.finished
        finding("$label: capture task never completed (reader did not observe EOF)")
    end
    # The raw capture buffer legitimately holds raw bytes; the contract is that
    # every path out of it to the model or the DB yields valid UTF-8.
    try
        ev = Claw._truncate_pty_output(r.out, 65_536)
        isvalid(String, ev) || finding("$label: event payload is not valid UTF-8")
        JSON.json(ev)
    catch e
        finding("$label: event payload path threw $(typeof(e))")
    end
    # Claw ships captured PTY output to the model through this helper
    try
        t = LLMTools.truncate_tool_output(r.out; label = "PTY output")
        isvalid(String, t) || finding("$label: truncate_tool_output produced invalid UTF-8")
    catch e
        finding("$label: truncate_tool_output threw $(typeof(e))")
    end
end

println("== Claw PTY capture vs hostile output")
const CASES = [
    ("plain",          "echo hello"),
    ("binary",         "head -c 3000 /dev/urandom"),
    ("invalid_utf8",   raw"printf '\xff\xfe\x80\x80hello'"),
    ("truncated_utf8", raw"printf 'ok\xe2\x9c'"),
    ("nul_bytes",      raw"printf 'a\x00b\x00c'"),
    ("unicode",        "printf 'héllo ✓ 日本語 🎉\n'"),
    ("ansi",           raw"printf '\033[31mred\033[0m\033[2J'"),
    ("huge",           "yes abcdefghij | head -n 50000"),
    ("long_line",      "python3 -c \"print('x'*200000)\""),
    ("no_output",      "true"),
    ("nonzero",        "exit 7"),
    ("stderr",         "echo err >&2"),
    ("bad_cmd",        "this-command-does-not-exist-zz9"),
    ("slow_then_exit", "sleep 0.3; echo late"),
    ("progressive",    "for i in 1 2 3; do echo chunk\$i; sleep 0.15; done"),
]

for (name, cmd) in CASES
    print(rpad("  $name", 20))
    r = capture(cmd; wait_s = 20.0)
    check(name, r)
    println("ok (", sizeof(r.out), " bytes, finished=", r.finished, ")")
end

println("\n== gated capture (release line) and exit-code readback")
r = capture("IFS= read -r _; echo released"; release = "\n", wait_s = 20.0)
check("gated", r)
occursin("released", r.out) || finding("gated: release line did not reach the child (got $(repr(first(r.out, 80))))")
println("  gated ok: ", repr(first(r.out, 60)))

println("\n== rapid create/destroy churn")
for i in 1:12
    r = capture("printf 'iter$i'"; wait_s = 15.0)
    occursin("iter$i", r.out) || finding("churn[$i]: expected output missing (got $(repr(first(r.out, 60))))")
end
println("  churn ok")

println("\n", "="^70)
if isempty(FINDINGS)
    println("NO FINDINGS")
else
    println("FINDINGS (", length(FINDINGS), "):")
    for f in FINDINGS
        println("  - ", f)
    end
end
println("="^70)
