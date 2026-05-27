#!/bin/sh
# Container entrypoint:
#   1. Seed the global CLAUDE.md into the config dir if it is missing.
#   2. Lock down network egress automatically (unless disabled).
# Then exec the requested command.
set -e

# 1. Seed the global CLAUDE.md.
# Honors CLAUDE_CONFIG_DIR (Claude Code's config-dir override); falls back to
# ~/.claude. Keeps the default available even when the config dir is a mounted
# host directory or a fresh volume that shadows the baked-in copy. Only seeds
# when the file is absent, so a CLAUDE.md the user placed there is never touched.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
if [ ! -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
  mkdir -p "${CLAUDE_DIR}"
  cp /usr/local/share/claude-global.md "${CLAUDE_DIR}/CLAUDE.md"
  echo "Seeded default global CLAUDE.md at ${CLAUDE_DIR}/CLAUDE.md"
fi

# 2. Lock down network egress.
# Requires the container to be started with --cap-add=NET_ADMIN --cap-add=NET_RAW.
# Kept non-fatal: if the caps are missing (or setup fails) the container still
# starts, just without the egress allowlist. Set SANDBOX_SKIP_FIREWALL=1 to skip
# (e.g. for a first interactive login if it can't reach an auth host).
if [ "${SANDBOX_SKIP_FIREWALL:-0}" = "1" ]; then
  echo "SANDBOX_SKIP_FIREWALL=1 — skipping network lockdown."
elif sudo /usr/local/bin/init-firewall.sh >/tmp/init-firewall.log 2>&1; then
  echo "Network locked down — egress allowlist active (log: /tmp/init-firewall.log)."
else
  echo "WARNING: firewall setup failed — continuing WITHOUT network lockdown." >&2
  echo "  Start with --cap-add=NET_ADMIN --cap-add=NET_RAW. See /tmp/init-firewall.log:" >&2
  sed 's/^/  /' /tmp/init-firewall.log >&2 || true
fi

exec "$@"
