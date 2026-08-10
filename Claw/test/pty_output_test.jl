using Test
using Claw
using LLMTools

# Regression from fuzzing Claw's PTY capture path: a child can emit arbitrary
# bytes, and the captured text reaches the model (and SQLite) through event
# payloads. Those must be valid UTF-8 regardless.

@testset "PTY event payloads are valid UTF-8" begin
    raw = String(UInt8[0xff, 0xfe, 0x80, 0x41, 0x42, 0xe2, 0x9c])
    @test !isvalid(raw)

    # short enough to skip truncation
    @test isvalid(Claw._truncate_pty_output(raw, 1_000))
    # long enough to hit the truncation branch, whose index arithmetic would
    # otherwise run over malformed data
    @test isvalid(Claw._truncate_pty_output(raw^500, 100))
    # max_bytes <= 0 disables truncation but must still repair
    @test isvalid(Claw._truncate_pty_output(raw, 0))

    buf = IOBuffer()
    write(buf, raw)
    @test isvalid(Claw._drain_pty_buffer!(buf, 1_000))

    # valid text must pass through unchanged
    ok = "héllo ✓ 日本語 \U0001f389"
    @test Claw._truncate_pty_output(ok, 1_000) == ok
end

@testset "Claw PTY capture drains binary output cleanly" begin
    session = LLMTools.PtySessions.PtySession(`bash -lc "head -c 2000 /dev/urandom"`;
                                              dir = mktempdir())
    buf, lk, stop, task = Claw._start_pty_capture(session)
    finished = timedwait(() -> istaskdone(task), 30.0; pollint = 0.02) !== :timed_out
    stop[] = true
    timedwait(() -> istaskdone(task), 5.0; pollint = 0.02)
    out = Claw._take_pty_capture!(buf, lk)
    try
        close(session; force = true)
    catch
    end
    @test finished                       # reader observes EOF on its own
    @test isvalid(Claw._truncate_pty_output(out, 100_000))
    @test isvalid(LLMTools.truncate_tool_output(out; label = "PTY output"))
end
