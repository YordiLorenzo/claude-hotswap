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
5. **Secure storage** — Credentials stored in macOS Keychain (or encrypted files on Linux)

> **Running two Max/Pro subscriptions on one Mac?** Use **subscription tokens** (`add-token`), not config dirs. On macOS the Keychain holds only **one** OAuth login per OS user, so swapping `CLAUDE_CONFIG_DIR` does *not* switch accounts. A token from `claude setup-token` is injected via `CLAUDE_CODE_OAUTH_TOKEN`, sidesteps the Keychain entirely, and bills against the subscription's quota. See [Setting Up Multiple Subscriptions](#setting-up-multiple-subscriptions).

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

You can add **subscription tokens**, **API keys**, **config-dir subscriptions**, or a mix:

```bash
# Add a second Max/Pro subscription as a token (recommended on macOS)
claude setup-token                       # log in to the OTHER account, copy the sk-ant-oat... token
claude-hotswap add-token personal sk-ant-oat01-xxxxx "Personal Max"

# Add an Anthropic Console API key (pay-as-you-go, not subscription quota)
claude-hotswap add work sk-ant-api03-xxxxx "Work API key"

# Add a config-dir subscription (works cleanly on Linux; see caveat on macOS)
claude-hotswap add-sub team ~/.claude/hotswap/configs/team "Team account"
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

### Hands-free recovery without the wrapper

Don't want to run `claude-hot`? Enable auto-swap in the Stop hook. When a limit hits, the hook swaps to the next subscription, fires a notification, and records the session — so recovery is a single command:

```bash
# In your settings.json Stop-hook command, prefix with CLAUDE_HOTSWAP_AUTO=1
# (see Configuration → Environment Variables). Then, after a limit:
claude-hotswap resume             # continues the exact session on the new credential
```

> A live session **cannot** switch its own credential — see [Limitations](#limitations) for exactly why a relaunch is required. Auto-swap makes that relaunch a single keystroke; aliasing `claude` → `claude-hot` makes it fully automatic.

## Commands

| Command | Description |
|---------|-------------|
| `claude-hot [args]` | Drop-in `claude` wrapper with auto-swap on rate limit |
| `claude-hotswap status` | Show all keys and current session health |
| `claude-hotswap list` | List configured keys with status |
| `claude-hotswap add <name> <key> [note]` | Add a Console API key (stored in Keychain) |
| `claude-hotswap add-token <name> <token> [note]` | Add a subscription token from `claude setup-token` |
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
4. Fires a notification ("ping") — a macOS desktop alert by default, or any command you set via `CLAUDE_HOTSWAP_NOTIFY_CMD`
5. **If `CLAUDE_HOTSWAP_AUTO=1`:** performs the swap and records the session so `claude-hotswap resume` continues it on the new credential — no wrapper needed

### Key Types

| Type | Env Var | How It Works |
|------|---------|-------------|
| **Subscription Token** | `CLAUDE_CODE_OAUTH_TOKEN` | A long-lived token from `claude setup-token`. Authenticates against a Pro/Max **subscription** and uses its quota. Bypasses the Keychain, so multiple subscriptions coexist on one macOS user. **Recommended for multi-sub on macOS.** |
| **API Key** | `ANTHROPIC_API_KEY` | A Console API key. Overrides subscription auth. **Pay-as-you-go billing — not subscription quota.** |
| **Subscription (config dir)** | `CLAUDE_CONFIG_DIR` | An isolated config directory with its own OAuth login. Works cleanly on Linux. **On macOS the Keychain holds one login per OS user, so this does not isolate accounts — use a Subscription Token instead.** |

### Session Resume

When a rate limit is detected, the **session ID** is extracted from the JSONL filename. After swapping keys, `claude --resume <session-id>` picks up exactly where you left off — same conversation history, same context.

## Setting Up Multiple Subscriptions

### Recommended (macOS + Linux): subscription tokens

`claude setup-token` mints a long-lived token tied to whichever account you log in as. Generate one **per subscription** and register it. Because the token is injected via `CLAUDE_CODE_OAUTH_TOKEN` at launch, it never touches the shared Keychain, so two Max accounts coexist on one machine:

```bash
# Your primary account is already your ambient login (the "primary" key).
# Generate a token for the SECOND account:
claude setup-token
#   → opens a browser; sign in with the second account; copy the sk-ant-oat... token

claude-hotswap add-token second sk-ant-oat01-xxxxx "Second Max subscription"
```

After setup, `claude-hotswap list` shows both:

```
Claude Hotswap Keys (2 configured)

-> primary [SUB]   * AVAILABLE
      Main Claude subscription (ambient OAuth login)
   second [TOKEN]  * AVAILABLE
      Second Max subscription

Last swap: never
```

When `primary` hits its limit, a swap exports `CLAUDE_CODE_OAUTH_TOKEN` for `second` and the next launch runs on the second subscription's quota. Resume works because the session history stays in the same `~/.claude` (you are not changing `CLAUDE_CONFIG_DIR`).

> **Why not `add-sub` / `CLAUDE_CONFIG_DIR` on macOS?** Claude Code stores the subscription OAuth login in the macOS Keychain keyed by your **OS username** — one slot, shared by every config dir. Logging a second account into a second config dir overwrites the first's token, and `claude --resume` can't see sessions created under a different config dir. Config-dir subscriptions are the right tool on **Linux** (where credentials live in `$CLAUDE_CONFIG_DIR/.credentials.json`), not macOS.

### Config-dir subscriptions (Linux)

```bash
mkdir -p ~/.claude/hotswap/configs/work
CLAUDE_CONFIG_DIR=~/.claude/hotswap/configs/work claude   # run /login, then /exit
claude-hotswap add-sub work ~/.claude/hotswap/configs/work "Work Max subscription"
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_HOT_MAX_SWAPS` | `5` | Max consecutive swaps before giving up |
| `CLAUDE_HOT_DELAY` | `2` | Seconds to wait before auto-resuming |
| `CLAUDE_HOTSWAP_DIR` | `~/.claude/hotswap` | Data directory |
| `CLAUDE_HOTSWAP_AUTO` | _(unset)_ | When set (e.g. `1`), the Stop hook **performs** the swap automatically and saves the session so you can continue with a single `claude-hotswap resume` — no wrapper. Unset = the hook only suggests. |
| `CLAUDE_HOTSWAP_NOTIFY_CMD` | _(unset)_ | Command run with the alert text as `$1` when a limit is hit (your "ping"). Route it to Telegram, Slack, a webhook, etc. Falls back to a macOS desktop notification. |

Set the hook env vars in your settings.json hook entry, e.g.:

```json
{
  "type": "command",
  "command": "CLAUDE_HOTSWAP_AUTO=1 ~/.claude/hotswap/limit-detector-hook.sh",
  "timeout": 5
}
```

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

- **API keys and subscription tokens** are stored in macOS Keychain (`security` command) or in `~/.claude/hotswap/.secrets/` with `600` permissions on Linux
- **No secrets are stored in plain text** in `keys.json` — only metadata (name, type, status)
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

- **A live session cannot swap its own credential — a relaunch is unavoidable.** This isn't a missing feature; it's three independent facts about how Claude Code works:
  1. A subscription rate limit is **HTTP 429**, but Claude Code only re-fetches credentials (via `apiKeyHelper`) on **HTTP 401**. A 429 never triggers a credential refresh.
  2. Credential env vars (`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`) are read **once at process startup** and never re-read mid-session.
  3. A Stop hook can force the turn to continue, but that **does not issue a new API request**, so it can't pick up a new credential either.

  The only way to bind a running process to a different credential is to restart it. `claude-hot` owns that relaunch automatically; `CLAUDE_HOTSWAP_AUTO=1` + `claude-hotswap resume` reduces it to one keystroke. (A transparent local API proxy could swap upstream tokens without a restart, but that's out of scope — fragile across updates and ToS-sensitive.)
- **macOS subscriptions need tokens, not config dirs** — The macOS Keychain holds one OAuth login per OS user, shared across all `CLAUDE_CONFIG_DIR`s. Use `add-token` (from `claude setup-token`) to run multiple subscriptions. Config-dir subscriptions (`add-sub`) isolate accounts cleanly only on Linux.
- **Subscription isolation** — Each `CLAUDE_CONFIG_DIR` is fully independent. Settings, hooks, and permissions from your main config aren't shared.
- **macOS-focused storage** — Uses macOS Keychain for secrets. Linux uses encrypted files (`600`) as a fallback.

## License

MIT
