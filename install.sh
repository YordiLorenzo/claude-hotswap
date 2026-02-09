#!/usr/bin/env bash
# Claude Hotswap — Installer
#
# Installs claude-hotswap CLI and the Stop hook for automatic
# rate limit detection.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yordidekleijn/claude-hotswap/main/install.sh | bash
#   # or
#   git clone https://github.com/yordidekleijn/claude-hotswap.git && cd claude-hotswap && ./install.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${BOLD}Claude Hotswap — Installer${NC}"
echo ""

# Check dependencies
for dep in jq python3; do
  if ! command -v "$dep" &>/dev/null; then
    echo -e "${RED}Error: ${dep} is required but not installed.${NC}"
    if [[ "$dep" == "jq" ]]; then
      echo "  brew install jq  (macOS)"
      echo "  sudo apt install jq  (Ubuntu/Debian)"
    fi
    exit 1
  fi
done

if ! command -v claude &>/dev/null; then
  echo -e "${YELLOW}Warning: 'claude' CLI not found in PATH. Install Claude Code first.${NC}"
fi

# Determine source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTSWAP_DIR="${HOME}/.claude/hotswap"

echo -e "${BLUE}[1/6]${NC} Creating directories..."
mkdir -p "$HOTSWAP_DIR"

# Copy files
echo -e "${BLUE}[2/6]${NC} Installing CLI..."
if [[ -f "${SCRIPT_DIR}/bin/claude-hotswap" ]]; then
  cp "${SCRIPT_DIR}/bin/claude-hotswap" "${HOTSWAP_DIR}/claude-hotswap"
else
  # If running from curl pipe, download from GitHub
  echo -e "${CYAN}Downloading from GitHub...${NC}"
  curl -fsSL "https://raw.githubusercontent.com/yordidekleijn/claude-hotswap/main/bin/claude-hotswap" \
    -o "${HOTSWAP_DIR}/claude-hotswap"
fi
chmod +x "${HOTSWAP_DIR}/claude-hotswap"

echo -e "${BLUE}[3/6]${NC} Installing wrapper..."
if [[ -f "${SCRIPT_DIR}/bin/claude-hot" ]]; then
  cp "${SCRIPT_DIR}/bin/claude-hot" "${HOTSWAP_DIR}/claude-hot"
else
  curl -fsSL "https://raw.githubusercontent.com/yordidekleijn/claude-hotswap/main/bin/claude-hot" \
    -o "${HOTSWAP_DIR}/claude-hot"
fi
chmod +x "${HOTSWAP_DIR}/claude-hot"

echo -e "${BLUE}[4/6]${NC} Installing hook..."
if [[ -f "${SCRIPT_DIR}/hooks/limit-detector.sh" ]]; then
  cp "${SCRIPT_DIR}/hooks/limit-detector.sh" "${HOTSWAP_DIR}/limit-detector-hook.sh"
else
  curl -fsSL "https://raw.githubusercontent.com/yordidekleijn/claude-hotswap/main/hooks/limit-detector.sh" \
    -o "${HOTSWAP_DIR}/limit-detector-hook.sh"
fi
chmod +x "${HOTSWAP_DIR}/limit-detector-hook.sh"

# Symlink to PATH
echo -e "${BLUE}[5/6]${NC} Adding to PATH..."
LINK_TARGET=""
for dir in /usr/local/bin "${HOME}/.local/bin" "${HOME}/bin"; do
  if [[ -d "$dir" ]] && echo "$PATH" | tr ':' '\n' | grep -q "^${dir}$"; then
    ln -sf "${HOTSWAP_DIR}/claude-hotswap" "${dir}/claude-hotswap" 2>/dev/null \
      && ln -sf "${HOTSWAP_DIR}/claude-hot" "${dir}/claude-hot" 2>/dev/null \
      && LINK_TARGET="$dir" && break
  fi
done

if [[ -z "$LINK_TARGET" ]]; then
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${HOTSWAP_DIR}/claude-hotswap" "${HOME}/.local/bin/claude-hotswap"
  ln -sf "${HOTSWAP_DIR}/claude-hot" "${HOME}/.local/bin/claude-hot"
  LINK_TARGET="${HOME}/.local/bin"
  echo -e "${YELLOW}  Symlinked to ${LINK_TARGET}/{claude-hotswap,claude-hot}${NC}"
  echo -e "${YELLOW}  Make sure ${LINK_TARGET} is in your PATH:${NC}"
  echo -e "    export PATH=\"${LINK_TARGET}:\$PATH\""
else
  echo -e "${GREEN}  Symlinked to ${LINK_TARGET}/{claude-hotswap,claude-hot}${NC}"
fi

# Install hook into settings.json
echo -e "${BLUE}[6/6]${NC} Configuring Stop hook..."
SETTINGS_FILE="${HOME}/.claude/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
  # Check if Stop hook already exists
  if jq -e '.hooks.Stop' "$SETTINGS_FILE" &>/dev/null; then
    # Check if our hook is already there
    if jq -e '.hooks.Stop[] | .hooks[] | select(.command | contains("limit-detector"))' "$SETTINGS_FILE" &>/dev/null; then
      echo -e "${GREEN}  Stop hook already installed.${NC}"
    else
      # Add our hook to existing Stop hooks
      jq '.hooks.Stop += [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hotswap/limit-detector-hook.sh",
          "timeout": 5
        }]
      }]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      echo -e "${GREEN}  Stop hook added to existing hooks.${NC}"
    fi
  else
    # Add Stop key to hooks
    jq '.hooks.Stop = [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/hotswap/limit-detector-hook.sh",
        "timeout": 5
      }]
    }]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo -e "${GREEN}  Stop hook installed.${NC}"
  fi
else
  echo -e "${YELLOW}  No settings.json found. Create it manually or run Claude Code first.${NC}"
fi

# Initialize keys.json
"${HOTSWAP_DIR}/claude-hotswap" status &>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo -e "Quick start:"
echo -e "  ${BOLD}claude-hot${NC}                           Use instead of 'claude' (auto-swap on limit)"
echo -e "  ${BOLD}claude-hotswap status${NC}              Check current status"
echo -e "  ${BOLD}claude-hotswap add work sk-ant-...${NC}  Add an API key"
echo -e "  ${BOLD}claude-hotswap auto --resume${NC}        Manual swap + resume"
echo ""
echo -e "For full docs: ${CYAN}https://github.com/yordidekleijn/claude-hotswap${NC}"
