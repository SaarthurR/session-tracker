# Session Tracker

A macOS menu bar app that shows which coding-agent sessions are running right now, whether
each one is actually working or sitting idle, and which terminal or app it lives in.

Clicking a session focuses the exact terminal tab it is running in. Option-clicking reveals
its folder in Finder.

```
🧠 2/5
─────────────────────────────
Active coding sessions
🟢  Codex · api-server · 9 subagents   working
🟡  Claude Code · web-app · ttys000    idle 6m
⚪️  Cursor Agent · dashboard          idle 2h
─────────────────────────────
Apps open
  ChatGPT
  Claude
  Cursor
─────────────────────────────
✓ Notify when a session finishes
  Send test notification
  Quit
```

The title shows `working/total` when something is running, otherwise just the session count.

Recognises Claude Code, Codex (both the CLI and threads inside the ChatGPT desktop app),
Cursor Agent, Gemini, Aider, opencode, and jcode. Adding another takes one line.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools. If you do not have them:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/SaarthurR/session-tracker.git
cd session-tracker
./build.sh
open ~/Applications/SessionTracker.app
```

`build.sh` compiles the single Swift file into `SessionTracker.app` and installs it to
`~/Applications`. Pass a directory to install elsewhere: `./build.sh /Applications`.

There is no Xcode project and no dependencies. A 🧠 appears in the menu bar; the app has no
dock icon and no window.

Two permissions may be requested, both optional and both only on first use. Focusing a
specific terminal tab asks for Automation, and declining still brings the terminal to the
front. Notifications are covered below.

To uninstall, quit from the menu and delete `~/Applications/SessionTracker.app`.

### Start at login

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/SessionTracker.app", hidden:true}'
```

## How detection works

Finding agent sessions is harder than grepping `ps` for a name, because none of these tools
present themselves the obvious way:

- **The command name lies.** The real binary behind `claude` is a version-numbered file like
  `~/.local/share/claude/versions/2.1.226`, and behind `cursor-agent` it is plain `node`. So
  sessions are matched on `argv[0]`, read via `KERN_PROCARGS2`, not on the executable path.
- **Desktop apps look like sessions.** `/Applications/Cursor.app/...`, `Claude.app` and
  ChatGPT's bundled `codex` binary all contain those names. Anything running inside a
  `.app` bundle is excluded and listed separately under "Apps open".
- **Codex Desktop threads have no process.** They run inside ChatGPT.app, so they are found
  by reading `~/.codex/sessions/**/rollout-*.jsonl` instead. Threads are grouped by their
  root `session_id`, so a swarm shows as one session with a subagent count rather than
  fifteen rows.
- **Background helpers are not sessions.** `jcode menubar` and `jcode setup-hotkey` are
  filtered out by subcommand, and a session spawned by another session is counted once.

## Working vs idle

A live process is not a busy one. Activity is measured two ways:

- **Processes:** CPU time consumed between two scans, summed across the whole process
  subtree. An agent waiting for you burns none, but an agent that shelled out to a build
  also burns none while its child does the work, which would otherwise read as idle.
- **Codex threads:** the last event in the transcript. A finished turn ends with
  `task_complete`; anything else means it is mid-turn.

Idle time for Claude Code comes from the newest transcript in `~/.claude/projects` matching
that working directory. Sessions go 🟢 working → 🟡 idle under 15 minutes → ⚪️ idle longer.

## Clicking a session

The parent chain is walked up from the agent process until it reaches a process that owns a
real GUI app, which is the terminal it was launched from. That app is activated, and for
Terminal and iTerm2 an AppleScript then selects the specific tab matching the session's tty.

Tab selection needs Automation permission, requested once on first click. If it is denied,
the terminal still comes to the front, just not the specific tab. Sessions with no parent
terminal, like `cursor-agent`, fall back to activating Cursor.

Codex threads have no terminal, and activating ChatGPT is not enough when several
conversations are open. They open through `codex://threads/<id>`, the URL scheme ChatGPT
registers and uses for its own "copy link" feature. For a top-level thread the id is the
`session_id` in its rollout transcript, which is what sessions are already grouped by.

## Notifications

When a session that was working goes quiet, it sends a notification so you can go check on
it. Quiet means several consecutive scans with no CPU, not a single one, so a pause between
turns does not fire it. Toggle it from the menu; "Send test notification" checks delivery.

Delivery has a wrinkle. `UserNotifications` is preferred because a notification can then be
clicked to focus the session that sent it, but it needs a permission macOS refuses to grant
an ad-hoc signed app: without a signing certificate the app has no stable identity, so
`requestAuthorization` fails with "Notifications are not allowed for this application".
The fallback posts the same banner through AppleScript, which needs no permission but
cannot carry a click action.

If you have an Apple Developer certificate, signing with it in `build.sh` instead of `-`
enables the native path and click-to-focus.

Regardless of which path is used, the menu bar icon turns into 🔔 when a session finishes,
and clears when you open the menu. That signal cannot be blocked by permissions.

## Cost

The scan avoids subprocesses entirely: `ps` and `lsof` cost ~300ms per scan in startup
overhead alone, against ~25ms for the equivalent `libproc` and `sysctl` calls. At a 5 second
refresh that is under 1% of one core.

```bash
./build.sh && ST_PROFILE=1 ~/Applications/SessionTracker.app/Contents/MacOS/SessionTracker --list
```

`--list` prints exactly what the menu would show, without launching the GUI. `ST_PROFILE=1`
adds per-phase timings.

## Adding another agent

Add its `argv[0]` name to `agentBinaries` in `SessionTracker.swift`. If it runs inside a
desktop app rather than as a process, it needs a transcript reader like the Codex one.
