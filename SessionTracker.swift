import Cocoa
import Darwin

// MARK: - Configuration

/// Command names that indicate a coding-agent session, matched against argv[0].
let agentBinaries: [String: String] = [
    "claude": "Claude Code",
    "codex": "Codex",
    "cursor-agent": "Cursor Agent",
    "jcode": "jcode",
    "gemini": "Gemini",
    "aider": "Aider",
    "opencode": "opencode",
]

/// Subcommands that mean "long-lived helper", not "someone is coding right now".
let backgroundSubcommands: Set<String> = [
    "menubar", "setup-hotkey", "app-server", "mcp", "mcp-server",
    "serve", "daemon", "update", "doctor", "completion",
]

let trackedBundleIDs: Set<String> = [
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "com.anthropic.claudefordesktop", // Claude
    "com.openai.codex",               // ChatGPT / Codex
]

let chatGPTBundleID = "com.openai.codex"
let cursorBundleID = "com.todesktop.230313mzl4w4u92"

let refreshInterval: TimeInterval = 5.0
/// CPU seconds burned between two scans before a session counts as working.
let workingCPUThreshold: Double = 0.05
/// A Codex thread has no process of its own, so it is listed while its transcript is this fresh.
let codexSessionWindow: TimeInterval = 30 * 60
/// Re-reading the tail of a transcript is only worth it while it is still changing.
let codexTailWindow: TimeInterval = 120
let claudeTranscriptWindow: TimeInterval = 24 * 60 * 60
/// Below this, a session is shown as recently active rather than idle.
let recentlyActiveWindow: TimeInterval = 15 * 60

// MARK: - Models

enum HostTarget {
    case app(pid: pid_t, tty: String?)
    case bundle(String)
    case unknown
}

struct Session {
    let agent: String
    let folder: String
    let path: String?
    let tty: String?
    var subtitle: String?
    let host: HostTarget
    let working: Bool
    let lastActivity: Date?

    var dot: String {
        if working { return "🟢" }
        guard let lastActivity else { return "⚪️" }
        return Date().timeIntervalSince(lastActivity) < recentlyActiveWindow ? "🟡" : "⚪️"
    }

    var statusText: String {
        if working { return "working" }
        guard let lastActivity else { return "idle" }
        return "idle \(humanDuration(Date().timeIntervalSince(lastActivity)))"
    }
}

struct DesktopApp {
    let name: String
    let pid: pid_t
}

struct Snapshot {
    var sessions: [Session] = []
    var apps: [DesktopApp] = []
}

// MARK: - Helpers

/// Set ST_PROFILE=1 to print per-phase timings to stderr.
let profiling = ProcessInfo.processInfo.environment["ST_PROFILE"] == "1"

func phase<T>(_ label: String, _ block: () -> T) -> T {
    guard profiling else { return block() }
    let start = Date()
    let result = block()
    let line = String(format: "  %-24@ %5.1fms\n", label as NSString, Date().timeIntervalSince(start) * 1000)
    FileHandle.standardError.write(Data(line.utf8))
    return result
}

func humanDuration(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    if minutes < 60 { return "\(max(minutes, 1))m" }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d"
}

func shortPath(_ path: String) -> String {
    if path == NSHomeDirectory() { return "~" }
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
}

/// One pass over a transcript tree with modification dates prefetched, which matters
/// because these directories hold hundreds of files and this runs every few seconds.
func recentTranscripts(in root: String, newerThan cutoff: Date) -> [(path: String, modified: Date)] {
    guard FileManager.default.fileExists(atPath: root),
          let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }

    var result: [(path: String, modified: Date)] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate,
              modified > cutoff else { continue }
        result.append((url.path, modified))
    }
    return result
}

/// Reads the tail of an append-only transcript.
func lastLine(ofFile path: String, chunk: Int = 8192) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: end > UInt64(chunk) ? end - UInt64(chunk) : 0)
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").last.map(String.init)
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

// MARK: - Process table

struct ProcEntry {
    let pid: pid_t
    let ppid: pid_t
    let tdev: dev_t
}

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let tty: String?
    let argv0: String
    var name: String { (argv0 as NSString).lastPathComponent }
}

/// Reads the process table through libproc instead of shelling out. Spawning ps and lsof
/// cost ~300ms per scan; these syscalls cost ~5ms, which is what makes a 5s refresh sane.
final class ProcessTable {
    private var buffer: [CChar]

    init() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        let max = sysctl(&mib, 2, &value, &size, nil, 0) == 0 ? Int(value) : 1 << 20
        buffer = [CChar](repeating: 0, count: max)
    }

    /// One sysctl for the whole table. Unlike proc_pidinfo this also works for processes
    /// owned by root, which matters because `login` sits between a shell and Terminal.
    func entries() -> [pid_t: ProcEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }

        var table: [pid_t: ProcEntry] = [:]
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            let proc = procs[index]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }
            table[pid] = ProcEntry(pid: pid, ppid: proc.kp_eproc.e_ppid, tdev: proc.kp_eproc.e_tdev)
        }
        return table
    }

    func ttyName(_ device: dev_t) -> String? {
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    /// argv[0] is the only reliable identity: the real binary behind `claude` is a
    /// version-numbered file, and behind `cursor-agent` it is plain `node`.
    func arguments(_ pid: pid_t, all: Bool = false) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let ok = buffer.withUnsafeMutableBufferPointer { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok, size > MemoryLayout<Int32>.size else { return [] }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        var index = MemoryLayout<Int32>.size

        func next() -> String? {
            while index < size, buffer[index] == 0 { index += 1 }
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            return buffer[start..<index].withUnsafeBufferPointer { pointer in
                pointer.baseAddress.flatMap {
                    String(bytes: UnsafeRawBufferPointer(start: $0, count: index - start), encoding: .utf8)
                }
            }
        }

        _ = next()  // executable path, which is not the command name
        guard let argv0 = next() else { return [] }
        guard all else { return [argv0] }
        var result = [argv0]
        while result.count < Int(argc), let argument = next() { result.append(argument) }
        return result
    }

    func taskInfo(_ pid: pid_t) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        return read == size ? info : nil
    }

    func cpuSeconds(_ pid: pid_t) -> Double? {
        taskInfo(pid).map { Double($0.ptinfo.pti_total_user + $0.ptinfo.pti_total_system) / 1e9 }
    }

    func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Candidate sessions: an agent command that is not part of a desktop app bundle.
    func agentProcesses(in table: [pid_t: ProcEntry]) -> [ProcInfo] {
        table.values.compactMap { entry in
            guard let argv0 = arguments(entry.pid).first, !argv0.contains(".app/"),
                  agentBinaries[(argv0 as NSString).lastPathComponent] != nil else { return nil }
            return ProcInfo(pid: entry.pid, ppid: entry.ppid, tty: ttyName(entry.tdev), argv0: argv0)
        }
    }
}

// MARK: - Scanner

struct CodexMeta {
    let cwd: String
    let rootID: String
    let isSubagent: Bool
}

final class Scanner {
    static let shared = Scanner()

    private let lock = NSLock()
    private let table = ProcessTable()
    private var codexMetaCache: [String: CodexMeta] = [:]
    private var claudeCWDCache: [String: String] = [:]
    private var previousCPU: [pid_t: Double] = [:]
    private var cached: Snapshot?
    private var cachedAt = Date.distantPast

    /// Reuses a recent result so opening the menu never waits on a scan.
    func snapshot(maxAge: TimeInterval = 0) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cachedAt) < maxAge { return cached }
        let result = scan()
        cached = result
        cachedAt = Date()
        return result
    }

    private func scan() -> Snapshot {
        var snapshot = Snapshot()
        let processes = phase("process table") { table.entries() }
        var candidates = phase("scan argv") { table.agentProcesses(in: processes) }

        candidates = candidates.filter { proc in
            let args = table.arguments(proc.pid, all: true)
            guard args.count > 1 else { return true }
            return !backgroundSubcommands.contains(args[1]) && !args[1].hasPrefix("--listen")
        }
        // A session spawned by another session is one session, not two.
        let livePIDs = Set(candidates.map(\.pid))
        candidates = candidates.filter { !livePIDs.contains($0.ppid) }

        let claudeActivity = phase("claude transcripts") { claudeActivityByCWD() }
        let runningApps = NSWorkspace.shared.runningApplications
        // Electron helpers are listed here too, and activating one of those does nothing.
        let appPIDs = Set(runningApps.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))

        var cpuNow: [pid_t: Double] = [:]
        var sessions: [Session] = []

        for proc in candidates {
            let cpu = table.cpuSeconds(proc.pid)
            cpuNow[proc.pid] = cpu
            let working: Bool
            if let cpu, let previous = previousCPU[proc.pid] {
                working = cpu - previous > workingCPUThreshold
            } else {
                working = false
            }
            let path = table.workingDirectory(proc.pid)
            let agent = agentBinaries[proc.name] ?? "Agent"

            sessions.append(Session(
                agent: agent,
                folder: path.map(shortPath) ?? "unknown folder",
                path: path,
                tty: proc.tty,
                subtitle: nil,
                host: hostTarget(for: proc, processes: processes, appPIDs: appPIDs),
                working: working,
                // Only Claude Code writes a transcript we can date; the rest fall back to CPU.
                lastActivity: agent == "Claude Code" ? path.flatMap { claudeActivity[$0] } : nil
            ))
        }

        sessions.append(contentsOf: phase("codex transcripts") { codexDesktopSessions() })
        previousCPU = cpuNow

        // Only disambiguate by terminal when two rows would otherwise read identically.
        var counts: [String: Int] = [:]
        for session in sessions { counts["\(session.agent)|\(session.folder)", default: 0] += 1 }
        snapshot.sessions = sessions.map { session in
            var session = session
            if counts["\(session.agent)|\(session.folder)"] ?? 0 > 1, session.subtitle == nil {
                session.subtitle = session.tty
            }
            return session
        }.sorted {
            if $0.working != $1.working { return $0.working }
            return ($0.agent, $0.folder) < ($1.agent, $1.folder)
        }

        snapshot.apps = runningApps
            .filter { trackedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .map { DesktopApp(name: $0.localizedName ?? "Unknown", pid: $0.processIdentifier) }
            .sorted { $0.name < $1.name }

        return snapshot
    }

    /// Walks up the parent chain to the process that owns a window, i.e. the terminal.
    private func hostTarget(for proc: ProcInfo, processes: [pid_t: ProcEntry], appPIDs: Set<pid_t>) -> HostTarget {
        var current = proc.ppid
        for _ in 0..<12 {
            guard current > 1 else { break }
            if appPIDs.contains(current) { return .app(pid: current, tty: proc.tty) }
            guard let parent = processes[current]?.ppid else { break }
            current = parent
        }
        // cursor-agent is reparented to launchd, so there is no chain left to walk.
        if proc.argv0.contains("/Cursor/") { return .bundle(cursorBundleID) }
        return .unknown
    }

    // MARK: Claude transcripts

    private func claudeActivityByCWD() -> [String: Date] {
        var activity: [String: Date] = [:]
        let cutoff = Date().addingTimeInterval(-claudeTranscriptWindow)
        for file in recentTranscripts(in: NSHomeDirectory() + "/.claude/projects", newerThan: cutoff) {
            guard let cwd = claudeCWD(file.path) else { continue }
            if let existing = activity[cwd], existing > file.modified { continue }
            activity[cwd] = file.modified
        }
        return activity
    }

    /// The cwd sits a few lines into the transcript and never changes, so cache it per file.
    private func claudeCWD(_ path: String) -> String? {
        if let cached = claudeCWDCache[path] { return cached }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8),
              let cwd = firstMatch("\"cwd\"\\s*:\\s*\"([^\"]*)\"", in: text) else { return nil }
        let unescaped = cwd.replacingOccurrences(of: "\\/", with: "/")
        claudeCWDCache[path] = unescaped
        return unescaped
    }

    // MARK: Codex Desktop threads

    /// Codex threads run inside ChatGPT.app, so no process exists to find them by.
    /// Their rollout transcripts are the only visible trace.
    private func codexDesktopSessions() -> [Session] {
        let cutoff = Date().addingTimeInterval(-codexSessionWindow)
        let recent = recentTranscripts(in: NSHomeDirectory() + "/.codex/sessions", newerThan: cutoff)
        guard !recent.isEmpty else { return [] }

        // Threads spawned as subagents belong to whichever thread the user actually started.
        var groups: [String: (cwd: String, latest: Date, subagents: Int)] = [:]
        var latestPath: [String: String] = [:]
        for entry in recent {
            guard let meta = codexMeta(entry.path) else { continue }
            var group = groups[meta.rootID] ?? (meta.cwd, entry.modified, 0)
            if entry.modified >= group.latest {
                group.latest = entry.modified
                latestPath[meta.rootID] = entry.path
            }
            if meta.isSubagent {
                group.subagents += 1
            } else {
                group.cwd = meta.cwd
            }
            groups[meta.rootID] = group
        }

        return groups.map { rootID, group in
            var working = false
            if Date().timeIntervalSince(group.latest) < codexTailWindow,
               let path = latestPath[rootID], let line = lastLine(ofFile: path) {
                // A finished turn ends with task_complete; anything else means mid-turn.
                working = !line.contains("\"type\":\"task_complete\"")
            }
            return Session(
                agent: "Codex",
                folder: shortPath(group.cwd),
                path: group.cwd,
                tty: nil,
                subtitle: group.subagents > 0 ? "\(group.subagents) subagent\(group.subagents == 1 ? "" : "s")" : nil,
                host: .bundle(chatGPTBundleID),
                working: working,
                lastActivity: group.latest
            )
        }
    }

    private func codexMeta(_ path: String) -> CodexMeta? {
        if let cached = codexMetaCache[path] { return cached }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192),
              let text = String(data: data, encoding: .utf8),
              let cwd = firstMatch("\"cwd\"\\s*:\\s*\"([^\"]*)\"", in: text) else { return nil }
        let meta = CodexMeta(
            cwd: cwd.replacingOccurrences(of: "\\/", with: "/"),
            rootID: firstMatch("\"session_id\"\\s*:\\s*\"([^\"]*)\"", in: text) ?? path,
            isSubagent: firstMatch("\"thread_source\"\\s*:\\s*\"([^\"]*)\"", in: text) == "subagent"
        )
        codexMetaCache[path] = meta
        return meta
    }
}

// MARK: - Focusing a session

func focus(_ host: HostTarget) {
    switch host {
    case .app(let pid, let tty):
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
        if let tty, let bundleID = app.bundleIdentifier { selectTab(bundleID: bundleID, tty: tty) }
    case .bundle(let bundleID):
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    case .unknown:
        break
    }
}

/// Best effort: this needs Automation permission, but the app is already frontmost either way.
func selectTab(bundleID: String, tty: String) {
    let device = "/dev/" + tty
    let source: String
    switch bundleID {
    case "com.apple.Terminal":
        source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set frontmost of w to true
                        set selected of t to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    case "com.googlecode.iterm2":
        source = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    default:
        return
    }
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

// MARK: - Menu bar

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "🧠"
        menu.delegate = self
        statusItem.menu = menu

        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        timer?.tolerance = 1.0
    }

    /// Also warms the CPU baseline that "working" is measured against.
    func refreshTitle() {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = Scanner.shared.snapshot()
            DispatchQueue.main.async { self.applyTitle(snapshot) }
        }
    }

    func applyTitle(_ snapshot: Snapshot) {
        let working = snapshot.sessions.filter(\.working).count
        let total = snapshot.sessions.count
        if total == 0 {
            statusItem.button?.title = "🧠"
        } else {
            statusItem.button?.title = working > 0 ? "🧠 \(working)/\(total)" : "🧠 \(total)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = Scanner.shared.snapshot(maxAge: 2)
        menu.removeAllItems()

        menu.addItem(header("Active coding sessions"))
        if snapshot.sessions.isEmpty {
            menu.addItem(disabled("No active sessions detected"))
        } else {
            for session in snapshot.sessions {
                var leading = "\(session.dot)  \(session.agent) · \(session.folder)"
                if let subtitle = session.subtitle { leading += " · \(subtitle)" }
                let item = NSMenuItem(title: leading, action: #selector(sessionClicked(_:)), keyEquivalent: "")
                item.attributedTitle = twoTone(leading, trailing: "   \(session.statusText)")
                item.target = self
                item.representedObject = SessionRef(session: session)
                item.toolTip = [session.path, session.tty.map { "tty \($0)" },
                                "Click to focus · Option-click to reveal folder"]
                    .compactMap { $0 }.joined(separator: "\n")
                menu.addItem(item)
            }
        }

        if !snapshot.apps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Apps open"))
            for app in snapshot.apps {
                let item = NSMenuItem(title: app.name, action: #selector(appClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: app.pid)
                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applyTitle(snapshot)
    }

    func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    func disabled(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func twoTone(_ leading: String, trailing: String) -> NSAttributedString {
        let string = NSMutableAttributedString(string: leading, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ])
        string.append(NSAttributedString(string: trailing, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        return string
    }

    @objc func sessionClicked(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SessionRef else { return }
        if NSEvent.modifierFlags.contains(.option) {
            if let path = ref.session.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            return
        }
        focus(ref.session.host)
    }

    @objc func appClicked(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.int32Value,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }
}

/// NSMenuItem.representedObject needs a class type.
final class SessionRef: NSObject {
    let session: Session
    init(session: Session) { self.session = session }
}

// MARK: - Entry point

// `--list` prints what the menu would show, so detection can be checked without a GUI.
if CommandLine.arguments.contains("--list") {
    // Two passes, because "working" is measured as CPU burned between scans.
    let coldStart = Date()
    _ = Scanner.shared.snapshot()
    let cold = Date().timeIntervalSince(coldStart)
    Thread.sleep(forTimeInterval: 1.0)
    let warmStart = Date()
    let snapshot = Scanner.shared.snapshot()
    let warm = Date().timeIntervalSince(warmStart)

    print(String(format: "scan: %.0fms cold, %.0fms warm", cold * 1000, warm * 1000))
    print("Sessions (\(snapshot.sessions.count))")
    for session in snapshot.sessions {
        let subtitle = session.subtitle.map { " · \($0)" } ?? ""
        let host: String
        switch session.host {
        case .app(let pid, let tty):
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            host = tty.map { "\(name) [\($0)]" } ?? name
        case .bundle(let id): host = id
        case .unknown: host = "unknown"
        }
        print("  \(session.dot) \(session.agent) · \(session.folder)\(subtitle)  [\(session.statusText)]  focus→ \(host)")
        print("      \(session.path ?? "-")")
    }
    print("Apps (\(snapshot.apps.count))")
    for app in snapshot.apps { print("  \(app.name)  pid \(app.pid)") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
