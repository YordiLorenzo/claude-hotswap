#!/usr/bin/env bash
# Claude Hotswap — End-to-End Test
#
# Simulates the full flow:
#   1. Add backup keys/subscriptions
#   2. Simulate a rate-limited session (fake JSONL transcript)
#   3. Detect the limit
#   4. Swap keys
#   5. Resume session
#   6. Test claude-hot wrapper with mock claude binary
#
# All operations use isolated temp directories — no side effects.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Test isolation — HOME is overridden so all paths resolve correctly
TEST_DIR=$(mktemp -d)
MOCK_PROJECTS="${TEST_DIR}/.claude/projects/-test-project"
MOCK_HOTSWAP="${TEST_DIR}/.claude/hotswap"
MOCK_BIN="${TEST_DIR}/bin"
FAKE_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

pass_count=0
fail_count=0
test_count=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test helpers
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  test_count=$((test_count + 1))
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    pass_count=$((pass_count + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  test_count=$((test_count + 1))
  if echo "$haystack" | grep -q "$needle"; then
    echo -e "  ${GREEN}PASS${NC} $label"
    pass_count=$((pass_count + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual output: ${haystack}"
    fail_count=$((fail_count + 1))
  fi
}

assert_exit() {
  local label="$1" expected_code="$2"
  shift 2
  test_count=$((test_count + 1))
  set +e
  "$@" >/dev/null 2>&1
  local code=$?
  set -e
  if [[ $code -eq $expected_code ]]; then
    echo -e "  ${GREEN}PASS${NC} $label (exit $code)"
    pass_count=$((pass_count + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "    expected exit: ${expected_code}"
    echo -e "    actual exit:   ${code}"
    fail_count=$((fail_count + 1))
  fi
}

# ─────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Claude Hotswap — E2E Test Suite${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${CYAN}Setting up test environment...${NC}"
mkdir -p "$MOCK_PROJECTS" "$MOCK_HOTSWAP" "$MOCK_BIN"

# Point everything at our test dirs
export CLAUDE_HOTSWAP_DIR="$MOCK_HOTSWAP"
export CLAUDE_HOTSWAP_FILE_STORAGE=1
export HOME="$TEST_DIR"

# Copy the CLI to mock hotswap dir
cp "${REPO_DIR}/bin/claude-hotswap" "${MOCK_HOTSWAP}/claude-hotswap"
chmod +x "${MOCK_HOTSWAP}/claude-hotswap"

# Copy claude-hot
cp "${REPO_DIR}/bin/claude-hot" "${MOCK_HOTSWAP}/claude-hot"
chmod +x "${MOCK_HOTSWAP}/claude-hot"

HOTSWAP="${MOCK_HOTSWAP}/claude-hotswap"
CLAUDE_HOT="${MOCK_HOTSWAP}/claude-hot"

echo -e "${GREEN}  Test dir: ${TEST_DIR}${NC}"
echo ""

# ─────────────────────────────────────────────────────
# TEST 1: Initialize & Default State
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 1: Initialization${NC}"

output=$("$HOTSWAP" status 2>&1) || true
assert_contains "status shows primary key" "primary" "$output"
assert_contains "status shows AVAILABLE" "AVAILABLE" "$output"

output=$("$HOTSWAP" current 2>&1) || true
assert_contains "current shows primary" "primary" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 2: Add API Key
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 2: Add API Key${NC}"

output=$("$HOTSWAP" add work "sk-ant-api03-test-key-12345" "Work API key" 2>&1) || true
assert_contains "add confirms success" "Added API key" "$output"

output=$("$HOTSWAP" list 2>&1) || true
assert_contains "list shows work key" "work" "$output"
assert_contains "list shows 2 configured" "2 configured" "$output"
assert_contains "work key is API type" "API" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 3: Add Subscription
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 3: Add Subscription${NC}"

MOCK_SUB_DIR="${TEST_DIR}/configs/personal"
mkdir -p "$MOCK_SUB_DIR"

output=$("$HOTSWAP" add-sub personal "$MOCK_SUB_DIR" "Personal Max" 2>&1) || true
assert_contains "add-sub confirms success" "Added subscription" "$output"

output=$("$HOTSWAP" list 2>&1) || true
assert_contains "list shows 3 configured" "3 configured" "$output"
assert_contains "personal key appears" "personal" "$output"
assert_contains "personal is SUB type" "SUB" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 4: Duplicate Key Prevention
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 4: Duplicate Key Prevention${NC}"

set +e
output=$("$HOTSWAP" add work "sk-ant-api03-another" "Dupe" 2>&1)
dupe_exit=$?
set -e
assert_contains "duplicate add rejected" "already exists" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 5: Simulate Rate Limit (create fake JSONL)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 5: Rate Limit Detection${NC}"

# Create a fake session transcript with rate limit at the end
FAKE_JSONL="${MOCK_PROJECTS}/${FAKE_SESSION_ID}.jsonl"
cat > "$FAKE_JSONL" <<'JSONL'
{"type":"system","cwd":"/Users/test/projects/my-app","sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"human","message":{"content":[{"type":"text","text":"fix the tests"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"I'll look at the test files..."}]},"model":"claude-opus-4-20250514"}
{"type":"human","message":{"content":[{"type":"text","text":"continue"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it..."}]},"model":"claude-opus-4-20250514"}
{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"model":"<synthetic>","message":{"content":[{"type":"text","text":"You've hit your usage limit for Claude Code · resets 4pm (Asia/Dubai)"}]}}
JSONL

output=$("$HOTSWAP" detect 2>&1) || true
assert_contains "detect finds LIMIT_HIT" "LIMIT_HIT" "$output"
assert_contains "detect shows session ID" "$FAKE_SESSION_ID" "$output"
assert_contains "detect shows reset time" "4pm" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 6: Auto-detect + Swap
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 6: Auto-detect + Swap${NC}"

output=$("$HOTSWAP" auto 2>&1) || true
assert_contains "auto detects rate limit" "Rate limit detected" "$output"
assert_contains "auto shows session ID" "$FAKE_SESSION_ID" "$output"
assert_contains "auto shows swap" "Swapped" "$output"
assert_contains "auto swaps to work" "work" "$output"

# Verify the swap happened
output=$("$HOTSWAP" current 2>&1) || true
assert_contains "current now shows work" "work" "$output"

# Verify primary is now exhausted
output=$("$HOTSWAP" list 2>&1) || true
assert_contains "primary is exhausted" "EXHAUSTED" "$output"

# Verify active-env.sh was created
test_count=$((test_count + 1))
if [[ -f "${MOCK_HOTSWAP}/active-env.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC} active-env.sh created"
  pass_count=$((pass_count + 1))
else
  echo -e "  ${RED}FAIL${NC} active-env.sh not created"
  fail_count=$((fail_count + 1))
fi

# Check active-env.sh contains the API key env var
if [[ -f "${MOCK_HOTSWAP}/active-env.sh" ]]; then
  env_content=$(cat "${MOCK_HOTSWAP}/active-env.sh")
  assert_contains "active-env.sh sets ANTHROPIC_API_KEY" "ANTHROPIC_API_KEY" "$env_content"
else
  test_count=$((test_count + 1))
  echo -e "  ${RED}FAIL${NC} active-env.sh sets ANTHROPIC_API_KEY (file missing)"
  fail_count=$((fail_count + 1))
fi

echo ""

# ─────────────────────────────────────────────────────
# TEST 7: Session Resume Info Saved
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 7: Session Resume Info${NC}"

saved_session=$(jq -r '.lastLimitedSession.id // empty' "${MOCK_HOTSWAP}/keys.json")
assert_eq "lastLimitedSession saved" "$FAKE_SESSION_ID" "$saved_session"

echo ""

# ─────────────────────────────────────────────────────
# TEST 8: Exhaust All Keys + Verify Failure
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 8: Exhaust All Keys${NC}"

# Swap again (work -> personal)
output=$("$HOTSWAP" swap 2>&1) || true
assert_contains "swap to personal" "personal" "$output"

# Now try swapping again — all should be exhausted
set +e
output=$("$HOTSWAP" swap 2>&1)
swap_exit=$?
set -e
assert_contains "no keys available" "No available keys" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 9: Reset All Keys
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 9: Reset Keys${NC}"

output=$("$HOTSWAP" reset 2>&1) || true
assert_contains "reset confirms" "All keys reset" "$output"

# Verify all keys are available again
output=$("$HOTSWAP" list 2>&1) || true

# Count AVAILABLE occurrences
available_count=$(echo "$output" | grep -c "AVAILABLE" || true)
assert_eq "all 3 keys available after reset" "3" "$available_count"

echo ""

# ─────────────────────────────────────────────────────
# TEST 10: Remove Key
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 10: Remove Key${NC}"

output=$("$HOTSWAP" remove personal 2>&1) || true
assert_contains "remove confirms" "Removed key" "$output"

output=$("$HOTSWAP" list 2>&1) || true
assert_contains "list shows 2 configured" "2 configured" "$output"

# Cannot remove primary
set +e
output=$("$HOTSWAP" remove primary 2>&1)
remove_exit=$?
set -e
assert_contains "cannot remove primary" "Cannot remove" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 11: Swap to Named Key
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 11: Swap to Named Key${NC}"

# Reset first
"$HOTSWAP" reset &>/dev/null

output=$("$HOTSWAP" swap work 2>&1) || true
assert_contains "swap to named key" "work" "$output"
assert_contains "swap confirms" "Swapped" "$output"

output=$("$HOTSWAP" current 2>&1) || true
assert_contains "current is work" "work" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 12: No Rate Limit — Clean Session
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 12: Clean Session Detection${NC}"

# Create a clean session (no rate limit)
CLEAN_SESSION_ID="11111111-2222-3333-4444-555555555555"
CLEAN_JSONL="${MOCK_PROJECTS}/${CLEAN_SESSION_ID}.jsonl"
# Make it newer than the rate-limited one
sleep 1
cat > "$CLEAN_JSONL" <<'JSONL'
{"type":"system","cwd":"/Users/test/projects/other","sessionId":"11111111-2222-3333-4444-555555555555"}
{"type":"human","message":{"content":[{"type":"text","text":"hello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi! How can I help?"}]},"model":"claude-opus-4-20250514"}
JSONL

set +e
output=$("$HOTSWAP" detect 2>&1)
detect_exit=$?
set -e
assert_contains "detect shows OK for clean session" "OK" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 13: claude-hot wrapper (full e2e with mock)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 13: claude-hot Wrapper (Full E2E)${NC}"

# Reset keys for this test
"$HOTSWAP" reset &>/dev/null
# Swap back to primary
jq '.current = 0' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"

# Create a mock 'claude' binary that:
#   - First call: writes a rate-limited JSONL, then exits
#   - Second call (--resume): writes a clean JSONL, then exits
MOCK_STATE="${TEST_DIR}/mock-state"
echo "0" > "$MOCK_STATE"

cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
CALL_NUM=\$(cat "${MOCK_STATE}")
CALL_NUM=\$((CALL_NUM + 1))
echo "\$CALL_NUM" > "${MOCK_STATE}"

PROJECTS_DIR="${MOCK_PROJECTS}"

if [[ \$CALL_NUM -eq 1 ]]; then
  # First call: simulate a session that hits rate limit
  SESSION="cccccccc-dddd-eeee-ffff-111111111111"
  sleep 1
  cat > "\${PROJECTS_DIR}/\${SESSION}.jsonl" <<'JSONL'
{"type":"system","cwd":"/Users/test/projects/app","sessionId":"cccccccc-dddd-eeee-ffff-111111111111"}
{"type":"human","message":{"content":[{"type":"text","text":"build the feature"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it..."}]},"model":"claude-opus-4-20250514"}
{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"model":"<synthetic>","message":{"content":[{"type":"text","text":"You've hit your usage limit · resets 6pm (Asia/Dubai)"}]}}
JSONL
  echo "Mock claude: Session \$SESSION hit rate limit"
  exit 0

elif [[ \$CALL_NUM -eq 2 ]]; then
  # Second call: should be --resume, simulate a successful session
  SESSION="cccccccc-dddd-eeee-ffff-111111111111"
  echo "Mock claude: Resumed session (args: \$*)"
  # Write a clean transcript on top
  sleep 1
  cat > "\${PROJECTS_DIR}/\${SESSION}.jsonl" <<'JSONL'
{"type":"system","cwd":"/Users/test/projects/app","sessionId":"cccccccc-dddd-eeee-ffff-111111111111"}
{"type":"human","message":{"content":[{"type":"text","text":"build the feature"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done! All tests pass."}]},"model":"claude-opus-4-20250514"}
JSONL
  echo "Mock claude: Session completed successfully"
  exit 0
fi
MOCK
chmod +x "${MOCK_BIN}/claude"

# Put mock bin first in PATH so claude-hot finds our mock
export PATH="${MOCK_BIN}:${PATH}"
export CLAUDE_HOT_DELAY=0

# Run claude-hot — it should:
# 1. Run mock claude (call 1 → rate limit)
# 2. Detect the limit
# 3. Swap keys
# 4. Resume with --resume (call 2 → success)
# 5. Exit cleanly
set +e
output=$("$CLAUDE_HOT" 2>&1)
hot_exit=$?
set -e

assert_eq "claude-hot exits cleanly" "0" "$hot_exit"
assert_contains "claude-hot: first call ran" "hit rate limit" "$output"
assert_contains "claude-hot: detected limit" "Auto Recovery" "$output"
assert_contains "claude-hot: swapped keys" "Swapped" "$output"
assert_contains "claude-hot: resumed session" "Resumed session" "$output"
assert_contains "claude-hot: completed" "completed successfully" "$output"

# Verify the mock was called twice
call_count=$(cat "$MOCK_STATE")
assert_eq "claude called exactly 2 times" "2" "$call_count"

echo ""

# ─────────────────────────────────────────────────────
# TEST 14: claude-hot with clean exit (no loop)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 14: claude-hot Clean Exit (No Swap)${NC}"

# Reset mock state
echo "0" > "$MOCK_STATE"

# Replace mock claude with one that just exits cleanly
cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
CALL_NUM=\$(cat "${MOCK_STATE}")
CALL_NUM=\$((CALL_NUM + 1))
echo "\$CALL_NUM" > "${MOCK_STATE}"

# Clean session — no rate limit
SESSION="dddddddd-eeee-ffff-0000-222222222222"
sleep 1
cat > "${MOCK_PROJECTS}/\${SESSION}.jsonl" <<'JSONL'
{"type":"system","cwd":"/tmp","sessionId":"dddddddd-eeee-ffff-0000-222222222222"}
{"type":"human","message":{"content":[{"type":"text","text":"hello"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi there!"}]},"model":"claude-opus-4-20250514"}
JSONL
echo "Mock claude: Clean session, no limit"
exit 0
MOCK
chmod +x "${MOCK_BIN}/claude"

set +e
output=$("$CLAUDE_HOT" 2>&1)
hot_exit=$?
set -e

assert_eq "claude-hot exits cleanly (no swap)" "0" "$hot_exit"
assert_contains "claude-hot: ran clean session" "Clean session" "$output"

# Verify no swap attempted (Auto Recovery should NOT appear)
test_count=$((test_count + 1))
if echo "$output" | grep -q "Auto Recovery"; then
  echo -e "  ${RED}FAIL${NC} claude-hot should not attempt swap on clean exit"
  fail_count=$((fail_count + 1))
else
  echo -e "  ${GREEN}PASS${NC} claude-hot did not attempt swap on clean exit"
  pass_count=$((pass_count + 1))
fi

call_count=$(cat "$MOCK_STATE")
assert_eq "claude called exactly 1 time (clean exit)" "1" "$call_count"

echo ""

# ─────────────────────────────────────────────────────
# TEST 15: claude-hot max swaps limit
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 15: claude-hot Max Swaps Limit${NC}"

# Reset everything
"$HOTSWAP" reset &>/dev/null
jq '.current = 0' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"
echo "0" > "$MOCK_STATE"

# Mock claude that always hits rate limit
cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
CALL_NUM=\$(cat "${MOCK_STATE}")
CALL_NUM=\$((CALL_NUM + 1))
echo "\$CALL_NUM" > "${MOCK_STATE}"

SESSION="eeeeeeee-ffff-0000-1111-\$(printf '%012d' \$CALL_NUM)"
sleep 1
cat > "${MOCK_PROJECTS}/\${SESSION}.jsonl" <<JSONL
{"type":"system","cwd":"/tmp","sessionId":"\${SESSION}"}
{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"model":"<synthetic>","message":{"content":[{"type":"text","text":"You've hit your limit · resets 8pm"}]}}
JSONL
echo "Mock claude: Rate limited (call \$CALL_NUM)"
exit 0
MOCK
chmod +x "${MOCK_BIN}/claude"

# Set max swaps to 2 for faster test
export CLAUDE_HOT_MAX_SWAPS=2

set +e
output=$("$CLAUDE_HOT" 2>&1)
hot_exit=$?
set -e

assert_eq "claude-hot exits non-zero after max swaps" "1" "$hot_exit"
assert_contains "claude-hot: swap failed or hit max" "No available keys\|max swap attempts" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 16: Stop Hook (limit-detector.sh)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 16: Stop Hook — Rate Limit Detection${NC}"

# Reset keys for hook test
"$HOTSWAP" reset &>/dev/null
jq '.current = 0' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"

# Create a rate-limited session for the hook to find
HOOK_SESSION="ffffffff-1111-2222-3333-444444444444"
HOOK_JSONL="${MOCK_PROJECTS}/${HOOK_SESSION}.jsonl"
sleep 1
cat > "$HOOK_JSONL" <<'JSONL'
{"type":"system","cwd":"/Users/test/hook-test","sessionId":"ffffffff-1111-2222-3333-444444444444"}
{"type":"human","message":{"content":[{"type":"text","text":"do stuff"}]}}
{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"model":"<synthetic>","message":{"content":[{"type":"text","text":"You've hit your usage limit · resets 5pm (Asia/Dubai)"}]}}
JSONL

HOOK_SCRIPT="${REPO_DIR}/hooks/limit-detector.sh"

# Feed hook input via stdin (simulating what Claude Code sends)
hook_input='{"transcript_path":"'"$HOOK_JSONL"'","session_id":"'"$HOOK_SESSION"'","stop_hook_active":false}'
output=$(echo "$hook_input" | "$HOOK_SCRIPT" 2>&1) || true

assert_contains "hook outputs systemMessage" "systemMessage" "$output"
assert_contains "hook mentions RATE LIMIT" "RATE LIMIT" "$output"
assert_contains "hook suggests swap command" "claude-hotswap" "$output"
assert_contains "hook mentions backup key" "work" "$output"

# Verify hook marked primary as exhausted
exhausted=$(jq -r '.keys[0].exhausted' "${MOCK_HOTSWAP}/keys.json")
assert_eq "hook marked primary exhausted" "true" "$exhausted"

echo ""

# ─────────────────────────────────────────────────────
# TEST 17: Stop Hook — Re-entry Prevention
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 17: Stop Hook — Re-entry Prevention (stop_hook_active)${NC}"

# Reset
"$HOTSWAP" reset &>/dev/null

# Send with stop_hook_active=true — hook should exit silently
hook_input='{"transcript_path":"'"$HOOK_JSONL"'","session_id":"'"$HOOK_SESSION"'","stop_hook_active":true}'
output=$(echo "$hook_input" | "$HOOK_SCRIPT" 2>&1) || true

# Should produce NO output (silent exit)
test_count=$((test_count + 1))
if [[ -z "$output" ]]; then
  echo -e "  ${GREEN}PASS${NC} hook exits silently on stop_hook_active=true"
  pass_count=$((pass_count + 1))
else
  echo -e "  ${RED}FAIL${NC} hook should exit silently on stop_hook_active=true"
  echo -e "    got: ${output}"
  fail_count=$((fail_count + 1))
fi

# Verify keys were NOT modified (still available after reset)
exhausted=$(jq -r '.keys[0].exhausted' "${MOCK_HOTSWAP}/keys.json")
assert_eq "hook did not modify keys on re-entry" "false" "$exhausted"

echo ""

# ─────────────────────────────────────────────────────
# TEST 18: Stop Hook — Clean Session (no rate limit)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 18: Stop Hook — Clean Session${NC}"

CLEAN_HOOK_JSONL="${MOCK_PROJECTS}/99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl"
sleep 1
cat > "$CLEAN_HOOK_JSONL" <<'JSONL'
{"type":"system","cwd":"/tmp","sessionId":"99999999-aaaa-bbbb-cccc-dddddddddddd"}
{"type":"assistant","message":{"content":[{"type":"text","text":"All done!"}]},"model":"claude-opus-4-20250514"}
JSONL

hook_input='{"transcript_path":"'"$CLEAN_HOOK_JSONL"'","session_id":"99999999-aaaa-bbbb-cccc-dddddddddddd","stop_hook_active":false}'
output=$(echo "$hook_input" | "$HOOK_SCRIPT" 2>&1) || true

test_count=$((test_count + 1))
if [[ -z "$output" ]]; then
  echo -e "  ${GREEN}PASS${NC} hook produces no output for clean session"
  pass_count=$((pass_count + 1))
else
  echo -e "  ${RED}FAIL${NC} hook should produce no output for clean session"
  echo -e "    got: ${output}"
  fail_count=$((fail_count + 1))
fi

echo ""

# ─────────────────────────────────────────────────────
# TEST 19: Stop Hook — All Keys Exhausted
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 19: Stop Hook — All Keys Exhausted${NC}"

# Exhaust all keys manually
"$HOTSWAP" reset &>/dev/null
local_data=$(cat "${MOCK_HOTSWAP}/keys.json")
echo "$local_data" | jq '.keys |= map(.exhausted = true)' > "${MOCK_HOTSWAP}/keys.json"

hook_input='{"transcript_path":"'"$HOOK_JSONL"'","session_id":"'"$HOOK_SESSION"'","stop_hook_active":false}'
output=$(echo "$hook_input" | "$HOOK_SCRIPT" 2>&1) || true

assert_contains "hook warns all exhausted" "No backup keys available" "$output"

# Reset after test
"$HOTSWAP" reset &>/dev/null

echo ""

# ─────────────────────────────────────────────────────
# TEST 20: Subscription Swap (CLAUDE_CONFIG_DIR)
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 20: Subscription Swap${NC}"

# Reset and set up for sub swap
jq '.current = 0' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"

# Re-add a subscription (personal was removed in test 10)
MOCK_SUB2="${TEST_DIR}/configs/team"
mkdir -p "$MOCK_SUB2"
"$HOTSWAP" add-sub team "$MOCK_SUB2" "Team subscription" &>/dev/null

# Remove the work key so next swap goes to the subscription
"$HOTSWAP" remove work &>/dev/null

# Swap from primary → team (subscription)
output=$("$HOTSWAP" swap 2>&1) || true
assert_contains "swapped to team subscription" "team" "$output"

# Check active-env.sh sets CLAUDE_CONFIG_DIR
if [[ -f "${MOCK_HOTSWAP}/active-env.sh" ]]; then
  env_content=$(cat "${MOCK_HOTSWAP}/active-env.sh")
  assert_contains "active-env.sh sets CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR" "$env_content"
  assert_contains "active-env.sh points to team config" "$MOCK_SUB2" "$env_content"
  assert_contains "active-env.sh unsets ANTHROPIC_API_KEY" "unset ANTHROPIC_API_KEY" "$env_content"
else
  test_count=$((test_count + 3))
  echo -e "  ${RED}FAIL${NC} active-env.sh not created for subscription swap"
  fail_count=$((fail_count + 3))
fi

echo ""

# ─────────────────────────────────────────────────────
# TEST 21: Resume Command
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 21: Resume Command${NC}"

# Set up a lastLimitedSession
jq --arg sid "abababab-cdcd-efef-0101-232323232323" \
   '.lastLimitedSession = {id: $sid, cwd: "/tmp"}' \
   "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"

# Mock claude that logs its args
echo "0" > "$MOCK_STATE"
cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
echo "RESUME_ARGS: \$*"
exit 0
MOCK
chmod +x "${MOCK_BIN}/claude"

output=$("$HOTSWAP" resume 2>&1) || true
assert_contains "resume shows session ID" "abababab-cdcd-efef-0101-232323232323" "$output"
assert_contains "resume passes --resume flag" "RESUME_ARGS: --resume abababab" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 22: Resume with no saved session
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 22: Resume — No Saved Session${NC}"

# Clear lastLimitedSession
jq 'del(.lastLimitedSession)' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"

set +e
output=$("$HOTSWAP" resume 2>&1)
resume_exit=$?
set -e
assert_contains "resume fails without saved session" "No rate-limited session" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 23: claude-hot with arguments
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 23: claude-hot Passes Arguments${NC}"

# Reset keys
"$HOTSWAP" reset &>/dev/null
jq '.current = 0' "${MOCK_HOTSWAP}/keys.json" > "${MOCK_HOTSWAP}/keys.json.tmp" \
  && mv "${MOCK_HOTSWAP}/keys.json.tmp" "${MOCK_HOTSWAP}/keys.json"
echo "0" > "$MOCK_STATE"

# Mock claude that logs args and writes a clean session
cat > "${MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
echo "ARGS_RECEIVED: \$*"
SESSION="77777777-8888-9999-aaaa-bbbbbbbbbbbb"
sleep 1
cat > "${MOCK_PROJECTS}/\${SESSION}.jsonl" <<'JSONL'
{"type":"system","cwd":"/tmp","sessionId":"77777777-8888-9999-aaaa-bbbbbbbbbbbb"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]},"model":"claude-opus-4-20250514"}
JSONL
exit 0
MOCK
chmod +x "${MOCK_BIN}/claude"

export CLAUDE_HOT_MAX_SWAPS=5

set +e
output=$("$CLAUDE_HOT" -p "fix the tests" --verbose 2>&1)
hot_exit=$?
set -e

assert_eq "claude-hot exits cleanly with args" "0" "$hot_exit"
assert_contains "claude-hot passes -p flag" "ARGS_RECEIVED: -p fix the tests --verbose" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 24: Detect with no sessions
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 24: Detect — No Sessions${NC}"

# Wipe all JSONL files
rm -f "${MOCK_PROJECTS}"/*.jsonl

set +e
output=$("$HOTSWAP" detect 2>&1)
detect_exit=$?
set -e
assert_contains "detect shows NO_SESSION" "NO_SESSION" "$output"

echo ""

# ─────────────────────────────────────────────────────
# TEST 25: Help and Unknown Commands
# ─────────────────────────────────────────────────────

echo -e "${BOLD}Test 25: Help & Error Handling${NC}"

output=$("$HOTSWAP" help 2>&1) || true
assert_contains "help shows usage" "Usage:" "$output"
assert_contains "help lists commands" "auto" "$output"

set +e
output=$("$HOTSWAP" nonsense 2>&1)
bad_exit=$?
set -e
assert_contains "unknown command shows error" "Unknown command" "$output"
assert_eq "unknown command exits non-zero" "1" "$bad_exit"

echo ""

# ─────────────────────────────────────────────────────
# RESULTS
# ─────────────────────────────────────────────────────

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [[ $fail_count -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}ALL ${test_count} TESTS PASSED${NC}"
else
  echo -e "  ${RED}${BOLD}${fail_count}/${test_count} TESTS FAILED${NC}"
fi
echo ""
echo -e "  Passed: ${GREEN}${pass_count}${NC}"
echo -e "  Failed: ${RED}${fail_count}${NC}"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

exit $fail_count
