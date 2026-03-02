using Claw, Telegram

const ClawTelegramExt = Base.get_extension(Claw, :ClawTelegramExt)

source = ClawTelegramExt.TelegramEventSource()
Claw.run(; event_sources=Claw.EventSource[source])
