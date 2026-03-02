using Claw, Signal

const ClawSignalExt = Base.get_extension(Claw, :ClawSignalExt)

source = ClawSignalExt.SignalEventSource()
Claw.run(; event_sources=Claw.EventSource[source])
