using Claw, Slack

const ClawSlackExt = Base.get_extension(Claw, :ClawSlackExt)

source = ClawSlackExt.SlackEventSource()
Claw.run(; event_sources=Claw.EventSource[source])
