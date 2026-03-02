using LLMOAuth
using Mattermost
using Claw

const ClawMattermostExt = Base.get_extension(Claw, :ClawMattermostExt)
ClawMattermostExt === nothing && error("ClawMattermostExt did not load; ensure Mattermost is available in this project")

# Ensures we have valid/refreshable Codex OAuth credentials before starting.
_, account_id = LLMOAuth.codex_login()
@info "Codex OAuth ready" account_id

provider = get(ENV, "CLAW_AGENT_PROVIDER", "openai-codex")
model_id = get(ENV, "CLAW_AGENT_MODEL", "gpt-5-codex")
assistant_name = get(ENV, "CLAW_ASSISTANT_NAME", "ando")
base_dir = get(ENV, "CLAW_BASE_DIR", abspath(joinpath(@__DIR__, "..", "..")))
db_path = joinpath(@__DIR__, "ando.sqlite")

sources = Claw.EventSource[
    ClawMattermostExt.MattermostEventSource(),
]

@info "Starting Ando project runner" assistant_name provider model_id db_path source_count=length(sources)
Claw.init!(db_path;
    event_sources=sources,
    name=assistant_name,
    provider=provider,
    model_id=model_id,
    apikey="OAUTH",
    base_dir=base_dir,
)

# Claw currently has no blocking run loop, so keep process alive.
wait(Base.Event())
