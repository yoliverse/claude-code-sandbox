#!/bin/sh
# Seed the global CLAUDE.md into ~/.claude on start if it is missing.
#
# Honors CLAUDE_CONFIG_DIR (Claude Code's config-dir override); falls back to
# ~/.claude. This keeps the default available even when the config dir is a
# mounted host directory or a fresh volume that shadows the baked-in copy. It
# only seeds when the file is absent, so a CLAUDE.md the user placed there is
# never touched.
set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
if [ ! -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
  mkdir -p "${CLAUDE_DIR}"
  cp /usr/local/share/claude-global.md "${CLAUDE_DIR}/CLAUDE.md"
  echo "Seeded default global CLAUDE.md at ${CLAUDE_DIR}/CLAUDE.md"
fi

exec "$@"
