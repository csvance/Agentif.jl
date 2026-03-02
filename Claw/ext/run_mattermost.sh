#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
# Mattermost credentials (override via env or edit here)
export MATTERMOST_URL="${MATTERMOST_URL:?Set MATTERMOST_URL (e.g. https://mattermost.example.com)}"
export MATTERMOST_TOKEN="${MATTERMOST_TOKEN:?Set MATTERMOST_TOKEN (bot access token)}"

# Claw / LLM provider credentials (override via env or edit here)
# export CLAW_AGENT_PROVIDER="anthropic"
# export CLAW_AGENT_MODEL="claude-sonnet-4-5-20250929"
# export CLAW_AGENT_API_KEY="sk-..."
# export CLAW_DATA_DIR="/path/to/persistent/data"

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAW_PROJECT="${SCRIPT_DIR}/.."
MATTERMOST_PKG="${CLAW_PROJECT}/../../Mattermost"
RUN_SCRIPT="${SCRIPT_DIR}/mattermost_run.jl"
LOG_FILE="${SCRIPT_DIR}/mattermost_bot.log"
PID_FILE="${SCRIPT_DIR}/mattermost_bot.pid"

# --- Ensure Mattermost is in the Claw project env ---
echo "Ensuring Mattermost package is available in Claw project..."
julia --project="$CLAW_PROJECT" -e "
    import Pkg
    deps = Pkg.dependencies()
    has_mattermost = any(p -> p.second.name == \"Mattermost\", deps)
    if !has_mattermost
        println(\"Adding Mattermost to Claw project...\")
        Pkg.develop(path=\"$MATTERMOST_PKG\")
    else
        println(\"Mattermost already in Claw project.\")
    end
    Pkg.instantiate()
"

# --- Stop existing bot if running ---
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing bot (PID $OLD_PID)..."
        kill "$OLD_PID"
        sleep 2
        kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null
    fi
    rm -f "$PID_FILE"
fi

# --- Launch bot in background ---
echo "Starting Mattermost bot..."
echo "  Log: $LOG_FILE"
echo "  PID file: $PID_FILE"

nohup julia --project="$CLAW_PROJECT" "$RUN_SCRIPT" >> "$LOG_FILE" 2>&1 &
BOT_PID=$!
echo "$BOT_PID" > "$PID_FILE"

echo "Bot started (PID $BOT_PID)"
echo ""
echo "Commands:"
echo "  tail -f $LOG_FILE        # follow logs"
echo "  kill \$(cat $PID_FILE)     # stop bot"
