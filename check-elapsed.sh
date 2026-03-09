#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# check-elapsed.sh — Show how long the current/last build has been running
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LATEST_DIR="$(cd "${SCRIPT_DIR}/output/latest" && pwd)"

err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

fmt_duration() {
  local secs="$1"
  printf "%dh %dm %ds" $(( secs / 3600 )) $(( secs % 3600 / 60 )) $(( secs % 60 ))
}

# ── Resolve output/latest ────────────────────────────────────────────
if [[ ! -L "${SCRIPT_DIR}/output/latest" && ! -d "$LATEST_DIR" ]]; then
  err "output/latest does not exist. No build has run yet."
  exit 1
fi

if [[ ! -d "$LATEST_DIR" ]]; then
  err "output/latest is a broken symlink."
  exit 1
fi

RESOLVED_DIR="$(cd "$LATEST_DIR" && pwd)"
RUN_NAME="$(basename "$RESOLVED_DIR")"

# ── Find the start marker (vm_setup.log) ─────────────────────────────
START_FILE="${LATEST_DIR}/vm_setup.log"
if [[ ! -f "$START_FILE" ]]; then
  err "vm_setup.log not found in ${LATEST_DIR}/. Build may not have started."
  exit 1
fi

# Birth time (creation) if supported, otherwise fall back to modification time
# stat -c %W = birth time (0 if unsupported), %Y = last modification
START_BIRTH="$(stat -c %W "$START_FILE" 2>/dev/null || echo 0)"
START_MTIME="$(stat -c %Y "$START_FILE" 2>/dev/null)"

if [[ "$START_BIRTH" -gt 0 ]]; then
  START_EPOCH="$START_BIRTH"
  START_TYPE="created"
else
  START_EPOCH="$START_MTIME"
  START_TYPE="modified (birth time unavailable)"
fi

START_HUMAN="$(date -d "@${START_EPOCH}" '+%Y-%m-%d %H:%M:%S')"

# ── Find the most recently modified file ──────────────────────────────
NEWEST_FILE=""
NEWEST_EPOCH=0

while IFS= read -r -d '' f; do
  mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  if [[ "$mtime" -gt "$NEWEST_EPOCH" ]]; then
    NEWEST_EPOCH="$mtime"
    NEWEST_FILE="$f"
  fi
done < <(find -L "$LATEST_DIR" -type f -print0)

if [[ -z "$NEWEST_FILE" ]]; then
  err "No files found in ${LATEST_DIR}/."
  exit 1
fi

NEWEST_HUMAN="$(date -d "@${NEWEST_EPOCH}" '+%Y-%m-%d %H:%M:%S')"
NEWEST_NAME="$(basename "$NEWEST_FILE")"

# ── Compute durations ────────────────────────────────────────────────
NOW_EPOCH="$(date +%s)"

BUILD_ELAPSED=$(( NEWEST_EPOCH - START_EPOCH ))
WALL_ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
SINCE_LAST_UPDATE=$(( NOW_EPOCH - NEWEST_EPOCH ))

# ── Output ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
info "Build run: ${RUN_NAME}"
echo ""
echo "  Start (vm_setup.log ${START_TYPE}):  ${START_HUMAN}"
echo "  Last file update (${NEWEST_NAME}):   ${NEWEST_HUMAN}"
echo "  Current time:                        $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ Build elapsed (start → last update):  $(fmt_duration $BUILD_ELAPSED)"
echo "  │ Wall elapsed  (start → now):          $(fmt_duration $WALL_ELAPSED)"
echo "  │ Since last update:                    $(fmt_duration $SINCE_LAST_UPDATE)"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

if [[ "$SINCE_LAST_UPDATE" -gt 3600 ]]; then
  warn "No file has been updated in over 1 hour. Build may be stuck."
elif [[ "$SINCE_LAST_UPDATE" -gt 1800 ]]; then
  warn "No file has been updated in over 30 minutes."
elif [[ "$SINCE_LAST_UPDATE" -lt 60 ]]; then
  ok "Build appears to be actively running."
fi

# Check if build.meta exists (indicates build completed)
if [[ -f "${LATEST_DIR}/build.meta" ]]; then
  ok "build.meta found — build has completed."
  echo "  Total build time: $(fmt_duration $BUILD_ELAPSED)"
else
  info "build.meta not found — build likely still in progress."
fi

echo "════════════════════════════════════════════════════════════════"
