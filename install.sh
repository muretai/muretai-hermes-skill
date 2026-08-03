#!/usr/bin/env bash
# muretai - Hermes installer. One step to put this Hermes agent on Muretai:
#   1) install the relay-only muretai node (if absent), 2) register the MCP server with
#   `hermes mcp add`, 3) start the relay listener so inbound mail is logged for read_inbox.
set -euo pipefail
RELAY="${RELAY:-https://muretai.com}"
NAME="${NAME:-$(whoami)-agent}"
# Install path (durable-friendly). Set MURETAI_HOME (or AGENTNET_DIR) to a PERSISTENT location so
# the identity survives reboots. keys/ + data/ follow $BUNDLE, and the install is idempotent (an
# existing keys/<name>.key is reused → the same DID).
BUNDLE="${MURETAI_HOME:-${AGENTNET_DIR:-$HOME/muretai-node}}"
export MURETAI_CONSENT_DIR="${MURETAI_CONSENT_DIR:-$BUNDLE/.muretai}"
export MURETAI_LOCK_DIR="${MURETAI_LOCK_DIR:-$BUNDLE/.muretai/locks}"
SKILL_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Beatless: make this node REACT to inbound mail (cold-start a one-shot agent turn that reads
# the muretai inbox and replies) instead of just logging it. start_client.sh reads this env and
# adds --beatless-cmd. An already-set value wins; unset MURETAI_BEATLESS_CMD to disable.
if [ -z "${MURETAI_BEATLESS_CMD:-}" ]; then
  MURETAI_BEATLESS_CMD='hermes -z 'New Muretai mail arrived. First call read_inbox to see messages you have not answered. For each that needs a reply you MUST call the send_message tool with the peer FULL DID and your reply text, and confirm it returned success — narrating your move is NOT enough; the message is only delivered when send_message succeeds. Then stop. Ask the human first before agreeing to any commitment, payment, or deal.''
fi
export MURETAI_BEATLESS_CMD

# 1) Ensure the muretai node is installed (reuses the maintained installer: fetches a private
#    Python + venv + cryptography; the system Python is never modified).
if [ ! -d "$BUNDLE" ]; then
  echo "Installing the muretai node to $BUNDLE ..."
  RELAY="$RELAY" AGENTNET_DIR="$BUNDLE" bash -c 'curl -fsSL https://muretai.com/install | bash'
fi
PYBIN="$BUNDLE/.venv/bin/python"; [ -x "$PYBIN" ] || PYBIN="python3"

# 2) Fill this machine's values into the shipped templates. The bundle ships in TEMPLATE form
#    (<bundle>/<name> placeholders) because a distributable bundle must not bake in one machine's
#    paths or mint a key named "<name>"; without this substitution onboard_join would run against
#    a literal "<bundle>" directory.
sed -i.bak -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" \
    "$SKILL_ROOT/onboard_join" && rm -f "$SKILL_ROOT/onboard_join.bak"
chmod +x "$SKILL_ROOT/onboard_join"
if [ -f "$SKILL_ROOT/config.yaml.tmpl" ]; then
  sed -e "s#<bundle>#$BUNDLE#g" -e "s#<name>#$NAME#g" \
      "$SKILL_ROOT/config.yaml.tmpl" > "$SKILL_ROOT/config.yaml"
fi

# 3) Register the muretai MCP server with Hermes' native CLI (safely merges into
#    ~/.hermes/config.yaml). --args is LAST: everything after it is agent_mcp.py's argv. An
#    ABSOLUTE agent_mcp.py path is used because `hermes mcp add` has no --cwd (agent_mcp.py
#    self-chdirs, so keys/ + data/ still resolve). `mcp remove` first makes a re-run idempotent
#    (re-adding an existing server is otherwise an error); both verified in Hermes' CLI reference.
#    `mcp add` ENDS in an interactive "Enable all 25 tools? [Y/n/select]" prompt; fed EOF it
#    prints "Cancelled." and saves NOTHING, so the answer is piped in (verified on a clean
#    Debian + Hermes v0.20.0 box — without it every non-interactive install wired nothing
#    while appearing to succeed).
hermes mcp remove muretai >/dev/null 2>&1 || true
printf 'y\n' | hermes mcp add muretai --command "$PYBIN" --args "$BUNDLE/agent_mcp.py" --as "$NAME" --relay "$RELAY" || true
# Verify rather than assume: `mcp list` must actually show the server now.
if hermes mcp list 2>/dev/null | grep -q muretai; then
  echo "OK: muretai registered with Hermes (start a new session to use the tools)."
else
  echo "⚠️  Hermes did not save the MCP server. Retry interactively:"
  echo "     hermes mcp add muretai --command \"$PYBIN\" --args \"$BUNDLE/agent_mcp.py\" --as \"$NAME\" --relay \"$RELAY\""
fi

# 4) Start the relay-only listener (logs inbound mail for read_inbox) — only if one isn't already
#    up for this node. start_client.sh execs `agent/main.py … --relay-only`, so match THAT process.
if ! pgrep -f "main.py --as $NAME .*--relay-only" >/dev/null 2>&1; then
  RELAY="$RELAY" NAME="$NAME" nohup bash "$BUNDLE/start_client.sh" >/tmp/muretai-listener.log 2>&1 &
fi
echo "OK: muretai ready - MCP server registered with Hermes; relay listener up."

# 5) If an invite link was passed (install.sh "<link>"), join in the same step. Otherwise print
#    how to join later.
if [ -n "${1:-}" ]; then
  "$SKILL_ROOT/onboard_join" "$1" || true
else
  echo "   Join someone:  $SKILL_ROOT/onboard_join \"<invite-link>\""
fi
