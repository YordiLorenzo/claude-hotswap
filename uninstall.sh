#!/usr/bin/env bash
# Claude Hotswap — Uninstaller

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${BOLD}Claude Hotswap — Uninstaller${NC}"
echo ""

# Remove symlinks
for dir in /usr/local/bin "${HOME}/.local/bin" "${HOME}/bin"; do
  if [[ -L "${dir}/claude-hotswap" ]]; then
    rm -f "${dir}/claude-hotswap"
    echo -e "${GREEN}Removed symlink: ${dir}/claude-hotswap${NC}"
  fi
done

# Remove Stop hook from settings.json
SETTINGS_FILE="${HOME}/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  if jq -e '.hooks.Stop' "$SETTINGS_FILE" &>/dev/null; then
    jq '.hooks.Stop |= map(select(.hooks | all(.command | contains("limit-detector") | not)))
        | if .hooks.Stop == [] then del(.hooks.Stop) else . end' \
      "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo -e "${GREEN}Removed Stop hook from settings.json${NC}"
  fi
fi

# Ask about data
echo ""
echo -e "${YELLOW}Remove hotswap data (~/.claude/hotswap)?${NC}"
echo -e "This includes your key registry (API keys remain in Keychain)."
echo -n "Remove? [y/N] "
read -r REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  rm -rf "${HOME}/.claude/hotswap"
  echo -e "${GREEN}Removed ~/.claude/hotswap${NC}"
else
  echo "Kept ~/.claude/hotswap"
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
