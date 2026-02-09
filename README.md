<p align="center">
  <img src="logo.svg" alt="claude-hotswap" width="180" />
</p>

<h1 align="center">claude-hotswap</h1>

<p align="center">
  Automatically detect Claude Code rate limits and swap to backup API keys or subscriptions — then resume your session exactly where you left off.
</p>

<p align="center">
  <a href="#install">Install</a> &middot;
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#commands">Commands</a> &middot;
  <a href="#how-it-works">How It Works</a>
</p>

---

```
$ claude-hot

  Working on your project...
  [rate limit hit — session frozen]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Claude Hotswap — Auto Recovery
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Rate limit detected on session: 196557c7-2189-4c1c-9c85-23356ed6323c
  Swap attempt: 1/5

Swapped: primary -> work [Subscription: ~/.claude/hotswap/configs/work]

Resuming session 196557c7-2189-4c1c-9c85-23356ed6323c in 2s...
Resuming...
```

## The Problem

Claude Code (Pro/Max) has usage limits that reset on a timer. When you hit the limit mid-task, your session stops and you have to wait. If you have multiple subscriptions or API keys, switching between them manually is tedious — you need to log out, log in, and lose your session context.

## The Solution

**claude-hotswap** gives you:

1. **`claude-hot` wrapper** — Drop-in replacement for `claude` that automatically detects rate limits, swaps keys, and resumes your session in a loop
2. **Automatic detection** — A Claude Code [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) monitors your session transcript for rate limit errors
3. **Key rotation** — Round-robin between multiple API keys or subscriptions
4. **Session resume** — Swap keys and resume your exact session with `claude --resume`
5. **Secure storage** — API keys stored in macOS Keychain (or encrypted files on Linux)

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
# Copy the CLI and wrapper
mkdir -p ~/.claude/hotswap
cp bin/claude-hotswap ~/.claude/hotswap/claude-hotswap
cp bin/claude-hot ~/.claude/hotswap/claude-hot
cp hooks/limit-detector.sh ~/.claude/hotswap/limit-detector-hook.sh
chmod +x ~/.claude/hotswap/claude-hotswap ~/.claude/hotswap/claude-hot ~/.claude/hotswap/limit-detector-hook.sh

# Add to PATH
ln -sf ~/.claude/hotswap/claude-hotswap /usr/local/bin/claude-hotswap
ln -sf ~/.claude/hotswap/claude-hot /usr/local/bin/claude-hot

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

### 2. Use `claude-hot` instead of `claude`

The easiest way — just use `claude-hot` as a drop-in replacement for `claude`:

```bash
claude-hot                        # Start a new session (auto-swap enabled)
claude-hot --resume <session-id>  # Resume a session (auto-swap enabled)
claude-hot -p "fix the tests"     # Any claude args work
```

When you hit a rate limit, `claude-hot` automatically:
1. Detects the limit in the transcript
2. Swaps to the next available key
3. Resumes the same session with the new credentials
4. Repeats up to 5 times (configurable via `CLAUDE_HOT_MAX_SWAPS`)

### 3. Manual mode (alternative)

If you prefer manual control:

```bash
claude-hotswap auto --resume      # Detect + swap + resume in one shot
# or step by step:
claude-hotswap auto               # Detect + swap (shows resume command)
claude-hotswap resume             # Resume the rate-limited session
```

### 4. After the limit resets

```bash
claude-hotswap reset              # Mark all keys as available again
```

## Commands

| Command | Description |
|---------|-------------|
| `claude-hot [args]` | Drop-in `claude` wrapper with auto-swap on rate limit |
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

### The `claude-hot` Wrapper

`claude-hot` is the recommended way to use claude-hotswap. It wraps the `claude` command and monitors session exits:

```
claude-hot
    │
    ├─► runs `claude` with your args
    │
    ├─► claude exits (you Ctrl+C after rate limit message)
    │
    ├─► checks last session transcript for rate_limit error
    │     │
    │     ├─► no rate limit → exits normally
    │     └─► rate limit found ─►
    │           │
    │           ├─► runs `claude-hotswap auto` (swap to next key)
    │           ├─► sources new credentials
    │           └─► runs `claude --resume <session-id>`
    │                 │
    │                 └─► loops back (up to MAX_SWAPS times)
    │
    └─► all keys exhausted → exits with status
```

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

When a rate limit is detected, the **session ID** is extracted from the JSONL filename. After swapping keys, `claude --resume <session-id>` picks up exactly where you left off — same conversation history, same context.

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

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_HOT_MAX_SWAPS` | `5` | Max consecutive swaps before giving up |
| `CLAUDE_HOT_DELAY` | `2` | Seconds to wait before auto-resuming |
| `CLAUDE_HOTSWAP_DIR` | `~/.claude/hotswap` | Data directory |

### Hook Configuration

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
rm -f /usr/local/bin/claude-hotswap /usr/local/bin/claude-hot
rm -rf ~/.claude/hotswap
# Remove the Stop hook from ~/.claude/settings.json
```

## Limitations

- **Cannot swap mid-session** — Claude Code's hooks can't change the active API key during a running session. The swap happens when the session exits (Ctrl+C after limit). `claude-hot` automates this entire flow.
- **Subscription isolation** — Each `CLAUDE_CONFIG_DIR` is fully independent. Settings, hooks, and permissions from your main config aren't shared.
- **macOS-focused** — Uses macOS Keychain for secure storage. Linux uses encrypted files as a fallback.

## License

MIT
