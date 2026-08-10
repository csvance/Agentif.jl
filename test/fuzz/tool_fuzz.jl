# Layer 1: deterministic tool-level fuzzing. No API cost.
#
# Drives LLMTools tools through the exact path the agent uses
# (JSON arg string -> parse_tool_arguments -> invoke_parsed_tool) with hostile
# inputs. A tool is allowed to fail, but only by returning an error *string* or
# throwing a clean, already-classified error; a raw crash, a hang, an invalid
# UTF-8 result, or a leaked absolute path outside the sandbox is a finding.

using Agentif, LLMTools, JSON, Random

const FINDINGS = String[]
finding(s) = (push!(FINDINGS, s); println("  !! FINDING: ", s))

const SANDBOX = mktempdir()

# ── hostile payload corpus ──────────────────────────────────────────────────
const PAYLOADS = Dict{String, Vector{UInt8}}(
    "empty"            => UInt8[],
    "nul_bytes"        => UInt8[0x00, 0x01, 0x00, 0x41, 0x00],
    "invalid_utf8"     => UInt8[0xff, 0xfe, 0x80, 0x80, 0x41],
    "truncated_utf8"   => UInt8[0xe2, 0x9c],                 # start of ✓, cut off
    "lone_surrogate"   => UInt8[0xed, 0xa0, 0x80],
    "ansi_escapes"     => Vector{UInt8}("\e[31mred\e[0m\e[2J\e[H\a\e]0;title\a"),
    "crlf_soup"        => Vector{UInt8}("a\r\nb\rc\nd\r\r\n\n"),
    "unicode_wide"     => Vector{UInt8}("h\u00e9llo w\u00f6rld \u2713 \u65e5\u672c\u8a9e \U0001f389 e\u0301 \u200b\u202e"),
    "long_line"        => Vector{UInt8}("x"^200_000),
    "many_lines"       => Vector{UInt8}(join(("line $i" for i in 1:50_000), "\n")),
    "json_injection"   => Vector{UInt8}("""{"tool":"evil","args":{"x":1}}\0"""),
    "backslashes"      => Vector{UInt8}("a\\b\\\\c\\\"d\\ne"),
)

function tool_by_name(tools, name)
    idx = findfirst(t -> Agentif.tool_name(t) == name, tools)
    idx === nothing ? nothing : tools[idx]
end

# Invoke exactly as the agent does: JSON string -> typed args -> func.
function call_tool(tool, argdict::Dict)
    argstr = JSON.json(argdict)
    T = typeof(tool).parameters[2]
    args = Agentif.parse_tool_arguments(argstr, T)
    return Agentif.invoke_parsed_tool(tool, args)
end

# Every tool result is embedded in a JSON transcript and shipped to a model, so
# it must be valid UTF-8 and JSON-encodable. This is the core invariant.
function check_result(label, result)
    if !(result isa AbstractString)
        finding("$label: result is $(typeof(result)), not a String")
        return
    end
    if !isvalid(String, result)
        finding("$label: result is not valid UTF-8 (len=$(sizeof(result)))")
        return
    end
    try
        JSON.json(result)
    catch e
        finding("$label: result is not JSON-encodable: $(sprint(showerror, e))")
    end
end

function guarded(label, f; timeout_s = 60.0)
    t = Threads.@spawn try
        f()
    catch e
        e
    end
    if timedwait(() -> istaskdone(t), timeout_s; pollint = 0.05) === :timed_out
        finding("$label: HUNG (no return within $(timeout_s)s)")
        return nothing
    end
    r = fetch(t)
    if r isa Exception
        # Clean, classified failures are fine; anything else is a finding.
        if r isa ArgumentError || r isa SystemError || r isa Base.IOError ||
           r isa Agentif.ToolArgumentError
            println("    (clean throw) $label: ", first(sprint(showerror, r), 90))
        else
            finding("$label: threw $(typeof(r)): $(first(sprint(showerror, r), 160))")
        end
        return nothing
    end
    check_result(label, r)
    return r
end

println("== sandbox: $SANDBOX")

# ── 1. file tools vs hostile file contents ──────────────────────────────────
println("\n== file tools vs hostile payloads")
ro = read_only_tools(SANDBOX)
coding = coding_tools(SANDBOX)
read_tool = tool_by_name(ro, "read")
grep_tool = tool_by_name(ro, "grep")
ls_tool = tool_by_name(ro, "ls")
find_tool = tool_by_name(ro, "find")
write_tool = tool_by_name(coding, "write")
edit_tool = tool_by_name(coding, "edit")

for (name, bytes) in sort(collect(PAYLOADS); by = first)
    path = joinpath(SANDBOX, "payload_$name.bin")
    write(path, bytes)
    guarded("read($name)", () -> call_tool(read_tool, Dict("path" => path)))
    guarded("grep($name)", () -> call_tool(grep_tool, Dict("pattern" => "a", "path" => SANDBOX)))
end

# ── 2. path traversal / sandbox escape ──────────────────────────────────────
println("\n== path traversal attempts")
const ESCAPES = [
    "../../../../etc/passwd",
    "/etc/passwd",
    joinpath(SANDBOX, "..", "..", "etc", "passwd"),
    "~/.ssh/id_rsa",
    "\0/etc/passwd",
    "subdir/../../../../../../etc/passwd",
    "....//....//etc/passwd",
]
for esc in ESCAPES
    r = guarded("read(escape=$(repr(esc)))", () -> call_tool(read_tool, Dict("path" => esc)))
    if r isa AbstractString && (occursin("root:x:", r) || occursin("BEGIN OPENSSH", r))
        finding("read escaped the sandbox with $(repr(esc)): returned real /etc/passwd or key material")
    end
end

# ── 3. write/edit with hostile content ──────────────────────────────────────
println("\n== write/edit hostile content")
for (name, bytes) in sort(collect(PAYLOADS); by = first)
    isvalid(String, String(copy(bytes))) || continue   # write takes String content
    content = String(copy(bytes))
    p = joinpath(SANDBOX, "w_$name.txt")
    guarded("write($name)", () -> call_tool(write_tool, Dict("path" => p, "content" => content)))
    guarded("edit($name)", () -> call_tool(edit_tool,
        Dict("path" => p, "oldText" => content, "newText" => "replaced")))
end
# edit with empty old_string, and with old_string not present
p = joinpath(SANDBOX, "edit_edge.txt")
write(p, "hello world")
guarded("edit(empty oldText)", () -> call_tool(edit_tool,
    Dict("path" => p, "oldText" => "", "newText" => "X")))
guarded("edit(absent oldText)", () -> call_tool(edit_tool,
    Dict("path" => p, "oldText" => "nonexistent-zzz", "newText" => "X")))

# ── 4. terminal tools: the PtySessions-backed path ──────────────────────────
println("\n== terminal tools vs hostile commands")
term = LLMTools.create_terminal_tools(SANDBOX)
exec_tool = tool_by_name(term, "exec_command")
write_stdin_tool = tool_by_name(term, "write_stdin")
kill_tool = tool_by_name(term, "kill_session")
list_tool = tool_by_name(term, "list_sessions")

const COMMANDS = [
    ("binary_output",   "head -c 2000 /dev/urandom"),
    ("invalid_utf8",    raw"printf '\xff\xfe\x80\x80hello'"),
    ("truncated_utf8",  raw"printf 'ok\xe2\x9c'"),
    ("nul_bytes",       raw"printf 'a\x00b\x00c'"),
    ("huge_output",     "yes abcdefghij | head -n 200000"),
    ("long_line",       "python3 -c \"print('x'*500000)\""),
    ("ansi_escapes",    raw"printf '\033[31mred\033[0m\033[2J'"),
    ("unicode",         "printf 'héllo wörld ✓ 日本語 🎉\n'"),
    ("no_output",       "true"),
    ("nonzero_exit",    "exit 42"),
    ("stderr_only",     "echo oops >&2"),
    ("immediate_exit",  "printf done; exit 0"),
    ("bad_command",     "this-command-does-not-exist-zz9"),
    ("crlf",            raw"printf 'a\r\nb\rc\n'"),
]

for (name, cmd) in COMMANDS
    guarded("exec($name)", () -> call_tool(exec_tool,
        Dict("cmd" => cmd, "yield_time_ms" => 2000)); timeout_s = 90.0)
end

# long-running session lifecycle: exec -> write_stdin -> kill
println("\n== terminal session lifecycle")
res = guarded("exec(interactive cat)", () -> call_tool(exec_tool,
    Dict("cmd" => "cat", "yield_time_ms" => 300)); timeout_s = 60.0)
sid = nothing
if res isa AbstractString
    try
        sid = get(JSON.parse(res), "session_id", nothing)
    catch e
        finding("exec result is not JSON: $(first(res, 120))")
    end
end
if sid === nothing
    finding("exec(`cat`) returned no session_id; cannot test session lifecycle")
else
    for (name, chars) in [("plain", "hello\n"), ("unicode", "héllo ✓ 日本語\n"),
                          ("huge", "z"^100_000 * "\n"), ("ansi", "\e[31mx\e[0m\n"),
                          ("empty", "")]
        guarded("write_stdin($name)", () -> call_tool(write_stdin_tool,
            Dict("session_id" => sid, "chars" => chars, "yield_time_ms" => 500)); timeout_s = 60.0)
    end
    guarded("kill_session", () -> call_tool(kill_tool, Dict("session_id" => sid)))
    # operations on a dead session must degrade cleanly, not crash
    guarded("write_stdin(after kill)", () -> call_tool(write_stdin_tool,
        Dict("session_id" => sid, "chars" => "x\n")))
    guarded("kill_session(twice)", () -> call_tool(kill_tool, Dict("session_id" => sid)))
    guarded("write_stdin(bogus id)", () -> call_tool(write_stdin_tool,
        Dict("session_id" => 999999, "chars" => "x\n")))
    guarded("kill_session(bogus id)", () -> call_tool(kill_tool, Dict("session_id" => -1)))
end
guarded("list_sessions", () -> call_tool(list_tool, Dict()))

# ── 5. session-limit / concurrency pressure ─────────────────────────────────
println("\n== concurrent session pressure")
ids = Int[]
guarded("concurrent 30 sessions", function ()
    @sync for i in 1:30
        Threads.@spawn begin
            r = try
                call_tool(exec_tool, Dict("cmd" => "sleep 30", "yield_time_ms" => 100))
            catch e
                string(e)
            end
            try
                s = get(JSON.parse(r), "session_id", nothing)
                s === nothing || push!(ids, s)
            catch
            end
        end
    end
    return "spawned=$(length(ids))"
end; timeout_s = 180.0)
for id in ids
    try; call_tool(kill_tool, Dict("session_id" => id)); catch; end
end
guarded("list_sessions(after pressure)", () -> call_tool(list_tool, Dict()))

# ── 6. malformed tool arguments (what a confused model actually emits) ──────
println("\n== malformed tool arguments")
const BAD_ARGS = [
    ("wrong_type_int",    Dict("cmd" => 12345)),
    ("wrong_type_arr",    Dict("cmd" => ["ls", "-la"])),
    ("null_value",        Dict("cmd" => nothing)),
    ("missing_required",  Dict("workdir" => "/tmp")),
    ("extra_unknown",     Dict("cmd" => "echo hi", "bogus_field" => "x", "yield_time_ms" => 500)),
    ("negative_yield",    Dict("cmd" => "echo hi", "yield_time_ms" => -5)),
    ("huge_yield",        Dict("cmd" => "echo hi", "yield_time_ms" => typemax(Int))),
    ("nested_object",     Dict("cmd" => Dict("a" => 1))),
]
for (name, args) in BAD_ARGS
    guarded("exec(badargs:$name)", () -> call_tool(exec_tool, args); timeout_s = 30.0)
end
# raw malformed JSON, as an over-eager model emits
for (name, raw) in [("trailing_comma", "{\"cmd\":\"echo hi\",}"),
                    ("unquoted_key", "{cmd:\"echo hi\"}"),
                    ("truncated", "{\"cmd\":\"echo"),
                    ("not_object", "\"echo hi\""),
                    ("empty_string", "")]
    guarded("parse_args($name)", function ()
        T = typeof(exec_tool).parameters[2]
        return string(Agentif.parse_tool_arguments(raw, T))
    end; timeout_s = 30.0)
end

# ── 7. output projection / truncation on weird boundaries ───────────────────
println("\n== output truncation boundaries")
for (name, s) in [("multibyte", "日"^50_000), ("emoji", "🎉"^30_000),
                  ("combining", "é"^40_000), ("mixed", ("a✓日🎉" ^ 30_000))]
    guarded("truncate_tool_output($name)",
        () -> LLMTools.truncate_tool_output(s; label = "fuzz"))
    guarded("project_output($name)",
        () -> string(LLMTools.project_output(s, 100, 100)))
end

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
