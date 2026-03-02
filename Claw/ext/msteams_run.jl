using Claw, MSTeams

const ClawMSTeamsExt = Base.get_extension(Claw, :ClawMSTeamsExt)

source = ClawMSTeamsExt.MSTeamsEventSource()
Claw.run(; event_sources=Claw.EventSource[source])
