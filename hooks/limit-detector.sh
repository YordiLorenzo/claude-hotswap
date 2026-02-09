#!/usr/bin/env bash
# Claude Hotswap — Stop Hook
# Fires when Claude finishes responding. Detects rate limit errors
# in the session transcript and notifies the user with swap instructions.
#
# Hook event: Stop
# Install: Add to ~/.claude/settings.json under hooks.Stop
# See install.sh for automatic setup.

set -euo pipefail

HOTSWAP_DIR="${CLAUDE_HOTSWAP_DIR:-${HOME}/.claude/hotswap}"
KEYS_FILE="${HOTSWAP_DIR}/keys.json"
LOG_FILE="${HOTSWAP_DIR}/hook.log"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# Read hook input from stdin
INPUT=$(cat)

# Extract transcript path from hook input
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)

# Prevent infinite loops — if stop_hook_active is true, we're in a re-entry
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  log "stop_hook_active=true, skipping to prevent loop"
  exit 0
fi

# If no transcript, nothing to check
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  log "No transcript at: ${TRANSCRIPT_PATH}"
  exit 0
fi

# Check last 10 lines for rate_limit
RATE_LIMIT_LINE=$(tail -10 "$TRANSCRIPT_PATH" | grep '"error":"rate_limit"' 2>/dev/null | tail -1 || true)

if [[ -z "$RATE_LIMIT_LINE" ]]; then
  # No rate limit, exit clean
  exit 0
fi

log "RATE LIMIT DETECTED in session ${SESSION_ID}"

# Extract reset time
RESET_TIME=$(echo "$RATE_LIMIT_LINE" | python3 -c "
import sys, json, re
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        msg = obj.get('message', {})
        if isinstance(msg, dict):
            for c in msg.get('content', []):
                if isinstance(c, dict) and c.get('type') == 'text':
                    text = c.get('text', '')
                    m = re.search(r'resets?\s+([\d:]+\s*(?:am|pm)?(?:\s*\([^)]+\))?)', text, re.I)
                    if m:
                        print(m.group(1).strip())
                        break
    except:
        pass
" 2>/dev/null || true)

log "Reset time: ${RESET_TIME:-unknown}"

# Update current key as exhausted in keys.json
if [[ -f "$KEYS_FILE" ]]; then
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  CURRENT_IDX=$(jq -r '.current' "$KEYS_FILE")

  # Update exhausted status
  jq --argjson idx "$CURRENT_IDX" \
     --arg now "$NOW" \
     --arg resets "${RESET_TIME:-unknown}" \
     '.keys[$idx].exhausted = true | .keys[$idx].exhaustedAt = $now | .keys[$idx].resetsAt = $resets' \
     "$KEYS_FILE" > "${KEYS_FILE}.tmp" && mv "${KEYS_FILE}.tmp" "$KEYS_FILE"

  CURRENT_NAME=$(jq -r ".keys[$CURRENT_IDX].name" "$KEYS_FILE")
  KEY_COUNT=$(jq '.keys | length' "$KEYS_FILE")
  AVAILABLE=$(jq '[.keys[] | select(.active == true and .exhausted != true)] | length' "$KEYS_FILE")

  log "Marked '${CURRENT_NAME}' as exhausted. Available keys: ${AVAILABLE}/${KEY_COUNT}"

  # Check if there are available keys to swap to
  if [[ $AVAILABLE -gt 0 ]]; then
    # Find next available
    NEXT_NAME=$(jq -r --argjson cur "$CURRENT_IDX" '
      [.keys | to_entries[] | select(.key != $cur and .value.active == true and .value.exhausted != true)]
      | .[0].value.name // empty' "$KEYS_FILE")

    if [[ -n "$NEXT_NAME" ]]; then
      jq -n --arg name "$CURRENT_NAME" --arg next "$NEXT_NAME" \
        --arg avail "$AVAILABLE" --arg resets "${RESET_TIME:-unknown}" \
        '{systemMessage: "RATE LIMIT HIT on key '"'"'\($name)'"'"'. \($avail) backup key(s) available. Run: claude-hotswap auto --resume  to swap to '"'"'\($next)'"'"' and resume this session. Or: claude-hotswap auto (swap only) then claude-hotswap resume. Resets at: \($resets)"}'
      log "Suggested swap to '${NEXT_NAME}'"
      exit 0
    fi
  else
    jq -n --arg name "$CURRENT_NAME" --arg count "$KEY_COUNT" \
      --arg resets "${RESET_TIME:-unknown}" \
      '{systemMessage: "RATE LIMIT HIT on '"'"'\($name)'"'"'. No backup keys available! All \($count) keys exhausted. Earliest reset: \($resets). Add more keys with: claude-hotswap add <name> <api-key>"}'
    log "All keys exhausted!"
    exit 0
  fi
fi

# Fallback: just warn
echo '{"systemMessage": "Rate limit detected. Run '\''claude-hotswap auto'\'' to swap to a backup key."}'
exit 0
