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
- **Cursor chats have no process either.** Cursor keeps exactly one `cursor-agent … worker
  start` helper for all of its chats, so that process is neither one session nor busy when
  the chats are. It is filtered out, and chats are read from their transcripts in
  `~/.cursor/projects/<workspace>/agent-transcripts/` instead. A `cursor-agent` you started
  yourself in a terminal is still tracked as a process, and takes precedence over the
  transcript for the same folder.
- **Background helpers are not sessions.** `jcode menubar` and `jcode setup-hotkey` are
  filtered out by subcommand, and a session spawned by another session is counted once.

Cursor names those project directories after the workspace path with the slashes turned into
dashes, which is ambiguous the moment a folder contains a dash: `frizzle-frizzle-fun` is
either `frizzle/frizzle-fun` or a folder of that name. Each possible split is tried against
the filesystem, longest run first. Windows with no folder open are named after a timestamp
and are listed as "no folder".

## Working vs idle

A live process is not a busy one, and CPU is a poor way to tell them apart: an agent spends
a turn waiting on a server, not on your machine. A `cursor-agent` running a task burns 0.01
CPU seconds over 5 seconds, which is indistinguishable from one sitting at a prompt. So
every agent that keeps a transcript is read instead, and CPU is only the fallback for the
ones that do not:

- **Claude Code:** the last message in the transcript. A reply that stopped to call a tool,
  or a message on the way in, means a turn is in flight; a reply that stopped on its own
  terms means the turn is over. Claude also writes metadata lines during a turn as well as
  after one, so those are skipped rather than read as progress.
- **Codex threads:** a finished turn ends with `task_complete`.
- **Cursor chats:** a finished turn ends with `turn_ended`.
- **Everything else:** CPU time consumed between two scans, summed across the whole process
  subtree. An agent that shelled out to a build burns none itself while its child does the
  work, which would otherwise read as idle.

Freshness cannot stand in for any of this. Claude writes a line per step, but Cursor only
writes at the edges of a turn, so a chat grinding through a long one leaves its file
untouched for minutes. Only the marker decides. Staleness is used just as a safety valve
for a turn that will never close, because the session was killed or is sat waiting on a
permission prompt: 10 minutes for Claude, which narrates constantly, and 4 hours for Cursor,
which does not.

Sessions go 🟢 working → 🟡 idle under 15 minutes → ⚪️ idle longer.

Nothing in a Claude transcript names the process that writes it, so two sessions in the same
folder cannot be told apart by content. Each is matched to the transcript created closest to
when the process started, closest pairing first. That also handles a session that resumed a
two-day-old conversation, which pairs with its original file rather than the newest one.

## Clicking a session

The parent chain is walked up from the agent process until it reaches a process that owns a
real GUI app, which is the terminal it was launched from. That app is activated, and for
Terminal and iTerm2 an AppleScript then selects the specific tab matching the session's tty.

Tab selection needs Automation permission, requested once on first click. If it is denied,
the terminal still comes to the front, just not the specific tab.

Cursor chats have no terminal, and opening their workspace folder is wrong twice over: it
lands in the editor rather than the Agents window where the chats actually are, and it
prompts before opening a folder that is usually already open. They go through
`cursor://anysphere.cursor-deeplink/agent` instead, the route Cursor's own deeplink
extension maps to "open or focus the Agents window". There is no route for a single chat,
so it opens the window rather than the conversation you clicked.

Codex threads have no terminal, and activating ChatGPT is not enough when several
conversations are open. They open through `codex://threads/<id>`, the URL scheme ChatGPT
registers and uses for its own "copy link" feature. For a top-level thread the id is the
`session_id` in its rollout transcript, which is what sessions are already grouped by.

## Notifications

When a session that was working stops, it sends a notification so you can go check on it.
Stopped has to hold for several consecutive scans, not one, so a pause inside a turn does
not fire it. Toggle it from the menu; "Send test notification" checks delivery.

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
overhead alone, against ~25ms for the equivalent `libproc` and `sysctl` calls. Reading
transcripts costs about as much again, since finding the recent ones means stating every
file in the tree. A scan lands around 60ms on a background thread, so at a 5 second refresh
it stays near 1% of one core.

```bash
./build.sh && ST_PROFILE=1 ~/Applications/SessionTracker.app/Contents/MacOS/SessionTracker --list
```

`--list` prints exactly what the menu would show, without launching the GUI. `ST_PROFILE=1`
adds per-phase timings.

## Adding another agent

Add its `argv[0]` name to `agentBinaries` in `SessionTracker.swift`. If it runs inside a
desktop app rather than as a process, it needs a transcript reader like the Codex one.
