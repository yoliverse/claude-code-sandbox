#!/usr/bin/env bash
#
# migrate-session.sh — copy a local Claude Code session transcript into a
# workspace directory so it can be resumed inside the container.
#
# The container sets CLAUDE_CONFIG_DIR=/workspace/.claude, so sessions live at
#   <workspace-root>/.claude/projects/<key>/<session-id>.jsonl
# where <workspace-root> is the host dir you bind-mount to /workspace (the mount
# ROOT, e.g. the <dir> in `-v <dir>:/workspace`), and <key> is the container
# working directory with every non-alphanumeric char replaced by '-'. The script
# writes straight into that host dir — no running container or `docker cp` needed.
#
# Run it on the HOST (macOS/Linux), not inside the container.
set -euo pipefail

CONFIG_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

usage() {
  cat <<'EOF'
Usage: migrate-session.sh --workspace DIR [options]

Required:
  --workspace DIR    Host dir you bind-mount to /workspace — the MOUNT ROOT (the
                     <dir> in `-v <dir>:/workspace`), NOT a project subfolder.
                     The session is written under <DIR>/.claude.

Options:
  --session ID|PATH  Session id, or a path to a .jsonl transcript. If a bare id,
                     it is looked up in --source-dir. Default: newest session in
                     --source-dir.
  --source-dir DIR   Host Claude project dir to read from.
                     Default: the project dir for the current working directory.
  --dest-cwd PATH    The directory you will run `claude` from inside the
                     container. Determines where the transcript is placed so
                     `claude --resume` finds it. Default: /workspace
  --list             List sessions available in --source-dir, then exit.
  -h, --help         Show this help.

Example:
  # Mounted with `-v ~/Documents/Yoliverse:/workspace`, resume a session in the
  # container under /workspace/YoLingo/yolingo-server:
  ./scripts/migrate-session.sh \
    --workspace ~/Documents/Yoliverse \
    --dest-cwd /workspace/YoLingo/yolingo-server
EOF
}

# Encode an absolute path into Claude Code's project-dir key.
encode_path() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

WORKSPACE=""
SESSION=""
SOURCE_DIR=""
DEST_CWD="/workspace"
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)  WORKSPACE="${2:-}"; shift 2 ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
    --dest-cwd)   DEST_CWD="${2:-}"; shift 2 ;;
    --list)       LIST=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Default source dir = the project dir for the current working directory.
if [ -z "$SOURCE_DIR" ]; then
  SOURCE_DIR="$CONFIG_BASE/projects/$(encode_path "$PWD")"
fi

if [ "$LIST" -eq 1 ]; then
  echo "Sessions in $SOURCE_DIR:"
  ls -t "$SOURCE_DIR"/*.jsonl 2>/dev/null | while read -r f; do
    echo "  $(basename "$f" .jsonl)"
  done
  exit 0
fi

if [ -z "$WORKSPACE" ]; then
  echo "error: --workspace is required" >&2; usage >&2; exit 2
fi
if [ ! -d "$WORKSPACE" ]; then
  echo "error: workspace dir not found: $WORKSPACE" >&2; exit 1
fi
if [ ! -d "$WORKSPACE/.claude" ]; then
  echo "note: $WORKSPACE/.claude does not exist yet — double-check that --workspace is" >&2
  echo "      the dir you bind-mount to /workspace (the mount root), not a project subfolder." >&2
fi

# Resolve the source transcript file.
if [ -n "$SESSION" ] && [ -f "$SESSION" ]; then
  SRC_FILE="$SESSION"
elif [ -n "$SESSION" ]; then
  SRC_FILE="$SOURCE_DIR/$SESSION.jsonl"
else
  SRC_FILE="$(ls -t "$SOURCE_DIR"/*.jsonl 2>/dev/null | head -1 || true)"
fi

if [ -z "${SRC_FILE:-}" ] || [ ! -f "$SRC_FILE" ]; then
  echo "error: no session transcript found." >&2
  echo "  looked in: $SOURCE_DIR" >&2
  echo "  try '--list' to see available sessions, or pass '--session <id>'." >&2
  exit 1
fi

# The container's config dir is /workspace/.claude, so the dir you resume from
# must be an in-container path under /workspace.
case "$DEST_CWD" in
  /workspace|/workspace/*) : ;;
  *) echo "error: --dest-cwd must be an in-container path under /workspace (got: $DEST_CWD)" >&2; exit 2 ;;
esac

SESSION_ID="$(basename "$SRC_FILE" .jsonl)"
KEY="$(encode_path "$DEST_CWD")"
DEST_DIR="$WORKSPACE/.claude/projects/$KEY"

mkdir -p "$DEST_DIR"
cp "$SRC_FILE" "$DEST_DIR/$SESSION_ID.jsonl"

echo "Migrated session:"
echo "  from: $SRC_FILE"
echo "  to:   $DEST_DIR/$SESSION_ID.jsonl"
echo
echo "Next, inside the container (with $WORKSPACE mounted at /workspace):"
echo "  cd $DEST_CWD"
echo "  claude --resume $SESSION_ID    # or: claude --resume  (and pick it)"
