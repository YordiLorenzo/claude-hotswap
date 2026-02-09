# claude-hotswap

Automatically detect Claude Code rate limits and swap to backup API keys or subscriptions — then resume your session exactly where you left off.

```
$ claude-hotswap auto --resume

Claude Hotswap — Auto Mode

Rate limit detected!
  Session: 196557c7-2189-4c1c-9c85-23356ed6323c
  Working dir: /Users/you/projects/my-app
  Resets at: 4pm

Attempting swap...
Swapped: primary -> work [Subscription: ~/.claude/hotswap/configs/work]

Sourcing env and resuming session...
```

## The Problem

Claude Code (Pro/Max) has usage limits that reset on a timer. When you hit the limit mid-task, your session stops and you have to wait. If you have multiple subscriptions or API keys, switching between them manually is tedious — you need to log out, log in, and lose your session context.

## The Solution

**claude-hotswap** gives you:

1. **Automatic detection** — A Claude Code [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) monitors your session transcript for rate limit errors
2. **Key rotation** — Round-robin between multiple API keys or subscriptions
3. **Session resume** — Swap keys and resume your exact session with `claude --resume`
4. **Secure storage** — API keys stored in macOS Keychain (or encrypted files on Linux)

## Install

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/yordidekleijn/claude-hotswap/main/install.sh | bash
```

### From source

```bash
git clone https://github.com/yordidekleijn/claude-hotswap.git
cd claude-hotswap
./install.sh
```

### Manual install

```bash
# Copy the CLI
mkdir -p ~/.claude/hotswap
cp bin/claude-hotswap ~/.claude/hotswap/claude-hotswap
cp hooks/limit-detector.sh ~/.claude/hotswap/limit-detector-hook.sh
chmod +x ~/.claude/hotswap/claude-hotswap ~/.claude/hotswap/limit-detector-hook.sh

# Add to PATH
ln -sf ~/.claude/hotswap/claude-hotswap /usr/local/bin/claude-hotswap

# Add the Stop hook to ~/.claude/settings.json
# (see Hook Configuration below)
```

### Dependencies

- `jq` — JSON processor (`brew install jq` / `apt install jq`)
- `python3` — For parsing JSONL transcripts (pre-installed on most systems)
- `claude` — [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)

## Quick Start

### 1. Add backup credentials

You can add **API keys**, **additional subscriptions**, or both:

```bash
# Add an Anthropic API key
claude-hotswap add work sk-ant-api03-xxxxx "Work API key"

# Add another subscription (opens Claude for /login)
claude-hotswap add-sub personal ~/.claude/hotswap/configs/personal "Personal account"
```

### 2. When you hit a limit

One command does everything — detects the limit, swaps to the next available key, and resumes your session:

```bash
claude-hotswap auto --resume
```

Or step by step:

```bash
claude-hotswap auto           # Detect + swap (shows resume command)
claude-hotswap resume         # Resume the rate-limited session
```

### 3. After the limit resets

```bash
claude-hotswap reset          # Mark all keys as available again
```

## Commands

| Command | Description |
|---------|-------------|
| `claude-hotswap status` | Show all keys and current session health |
| `claude-hotswap list` | List configured keys with status |
| `claude-hotswap add <name> <key> [note]` | Add an API key (stored in Keychain) |
| `claude-hotswap add-sub <name> <dir> [note]` | Add a subscription config directory |
| `claude-hotswap swap [name]` | Swap to next available key (or named) |
| `claude-hotswap auto` | Auto-detect limit + swap |
| `claude-hotswap auto --resume` | Auto-detect + swap + resume session |
| `claude-hotswap resume` | Resume last limited session with new key |
| `claude-hotswap current` | Show the active key |
| `claude-hotswap detect` | Check if current session hit a limit |
| `claude-hotswap reset` | Reset all exhausted keys to available |
| `claude-hotswap remove <name>` | Remove a key |
| `claude-hotswap help` | Show help |

## How It Works

### Rate Limit Detection

Claude Code writes session transcripts as JSONL files in `~/.claude/projects/`. When a rate limit is hit, it writes a synthetic message:

```json
{
  "type": "assistant",
  "error": "rate_limit",
  "isApiErrorMessage": true,
  "message": {
    "content": [{"type": "text", "text": "You've hit your limit · resets 4pm (Asia/Dubai)"}]
  }
}
```

The **Stop hook** (`hooks/limit-detector.sh`) fires every time Claude finishes responding. It tails the transcript JSONL for this fingerprint and:

1. Marks the current key as exhausted in `keys.json`
2. Extracts the reset time
3. Outputs a `systemMessage` telling you which backup key is available

### Key Types

| Type | Env Var | How It Works |
|------|---------|-------------|
| **API Key** | `ANTHROPIC_API_KEY` | Overrides subscription auth. Pay-as-you-go billing. |
| **Subscription** | `CLAUDE_CONFIG_DIR` | Isolated config directory with its own OAuth login. Each subscription has independent rate limits. |

### Session Resume

When `auto` detects a limit, it captures the **session ID** from the JSONL filename. After swapping keys, `claude --resume <session-id>` picks up exactly where you left off — same conversation history, same context.

## Setting Up Multiple Subscriptions

Each subscription needs its own isolated config directory so the OAuth tokens don't conflict:

```bash
# Create a directory and log in
mkdir -p ~/.claude/hotswap/configs/work
CLAUDE_CONFIG_DIR=~/.claude/hotswap/configs/work claude
# Inside Claude: run /login and authenticate with a different account
# Then /exit

# Register it
claude-hotswap add-sub work ~/.claude/hotswap/configs/work "Work Max subscription"
```

After setup, `claude-hotswap list` shows both:

```
Claude Hotswap Keys (2 configured)

-> primary [SUB] * AVAILABLE
      Main Claude subscription (OAuth login)
   work [SUB] * AVAILABLE
      Work Max subscription

Last swap: never
```

## Hook Configuration

The installer automatically adds this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hotswap/limit-detector-hook.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

The Stop hook fires every time Claude finishes a response. It runs in under 100ms for non-limit cases (just a `tail | grep`) so there's no noticeable overhead.

## Security

- **API keys** are stored in macOS Keychain (`security` command) or in `~/.claude/hotswap/.secrets/` with `600` permissions on Linux
- **No keys are stored in plain text** in `keys.json` — only metadata (name, type, status)
- The `active-env.sh` file (generated on swap) has `600` permissions and contains the active key for sourcing
- **`.secrets/` and `active-env.sh` are gitignored**

## Uninstall

```bash
./uninstall.sh
# or manually:
rm -f /usr/local/bin/claude-hotswap
rm -rf ~/.claude/hotswap
# Remove the Stop hook from ~/.claude/settings.json
```

## Limitations

- **Cannot swap mid-session** — Claude Code's hooks can't change the active API key during a running session. The swap happens between sessions, and you resume with `claude --resume`.
- **Subscription isolation** — Each `CLAUDE_CONFIG_DIR` is fully independent. Settings, hooks, and permissions from your main config aren't shared.
- **macOS-focused** — Uses macOS Keychain for secure storage. Linux uses encrypted files as a fallback.

## License

MIT
