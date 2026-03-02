using Claw, Mattermost

const ClawMattermostExt = Base.get_extension(Claw, :ClawMattermostExt)

source = ClawMattermostExt.MattermostEventSource()
Claw.run(; event_sources=Claw.EventSource[source])
