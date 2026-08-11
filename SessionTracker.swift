import Cocoa
import Darwin
import UserNotifications

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

/// `cursor-agent … worker start` is the single helper Cursor keeps running for all of its
/// own chats, so it is neither one session nor idle when its chats are busy. Those chats
/// are picked up from their transcripts instead.
func isBackgroundWorker(_ args: [String]) -> Bool {
    guard let index = args.firstIndex(of: "worker"), index + 1 < args.count else { return false }
    return args[index + 1] == "start"
}

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
/// Consecutive quiet scans before a session that was working is called finished. Guards
/// against notifying during a pause between turns.
let idleConfirmScans = 3
/// A Codex thread has no process of its own, so it is listed while its transcript is this fresh.
let codexSessionWindow: TimeInterval = 30 * 60
/// Re-reading the tail of a transcript is only worth it while it is still changing.
let codexTailWindow: TimeInterval = 120
let claudeTranscriptWindow: TimeInterval = 24 * 60 * 60
/// A finished Cursor chat stays listed this long, matching Codex.
let cursorSessionWindow: TimeInterval = 30 * 60
/// Cursor writes to a transcript only at the edges of a turn, so a chat grinding through
/// a long turn looks untouched. Mid-turn chats stay listed this long before being read
/// as abandoned rather than busy.
let cursorMidTurnWindow: TimeInterval = 4 * 60 * 60
/// Below this, a session is shown as recently active rather than idle.
let recentlyActiveWindow: TimeInterval = 15 * 60

// MARK: - Models

enum HostTarget {
    case app(pid: pid_t, tty: String?)
    case bundle(String)
    /// ChatGPT can open a specific conversation, which is the only way to tell two apart.
    case codexThread(String)
    /// Cursor has no link to a single chat, but reopening the folder raises its window.
    case cursorWorkspace(String?)
    case unknown

    var describedHost: String {
        switch self {
        case .app(let pid, let tty):
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            return tty.map { "\(name) · \($0)" } ?? name
        case .bundle(let bundleID):
            return NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
        case .codexThread: return "ChatGPT"
        case .cursorWorkspace: return "Cursor"
        case .unknown: return ""
        }
    }
}

struct Session {
    let key: String
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
    var id = 0
    var sessions: [Session] = []
    var apps: [DesktopApp] = []
    /// Sessions that finished working since the previous scan.
    var wentIdle: [Session] = []
}

/// Per-session history, kept between scans so a pause is not mistaken for finishing.
struct TrackState {
    var wasWorking = false
    var quietScans = 0
    var notified = false
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

/// Cursor names a project directory after its workspace path with the slashes turned into
/// dashes, so `/Users/me/Documents/frizzle/frizzle-fun` and a folder literally called
/// `frizzle-frizzle-fun` encode the same way. The only way back is to try each split
/// against the filesystem, longest run first. Windows with no folder open are named after
/// a timestamp instead and resolve to nothing.
func decodeWorkspace(_ encoded: String) -> String? {
    func walk(_ tokens: ArraySlice<String>, under base: String) -> String? {
        var end = tokens.endIndex
        while end > tokens.startIndex {
            let candidate = base + "/" + tokens[tokens.startIndex..<end].joined(separator: "-")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                if end == tokens.endIndex { return candidate }
                if let resolved = walk(tokens[end...], under: candidate) { return resolved }
            }
            end -= 1
        }
        return nil
    }
    let tokens = encoded.split(separator: "-").map(String.init)
    guard !tokens.isEmpty else { return nil }
    return walk(tokens[...], under: "")
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

    /// An agent shelling out to a build sits at zero CPU while its child does the work,
    /// so activity has to be measured across the whole subtree.
    func subtreeCPUSeconds(_ pid: pid_t, children: [pid_t: [pid_t]], limit: Int = 200) -> Double? {
        var total = cpuSeconds(pid)
        var queue = children[pid] ?? []
        var visited = 0
        while let next = queue.popLast(), visited < limit {
            visited += 1
            if let cpu = cpuSeconds(next) { total = (total ?? 0) + cpu }
            queue.append(contentsOf: children[next] ?? [])
        }
        return total
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
    private var cursorWorkspaceCache: [String: String?] = [:]
    private var turnEndedCache: [String: (modified: Date, ended: Bool)] = [:]
    private var previousCPU: [pid_t: Double] = [:]
    private var trackStates: [String: TrackState] = [:]
    private var scanCount = 0
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
            guard !isBackgroundWorker(args) else { return false }
            return !backgroundSubcommands.contains(args[1]) && !args[1].hasPrefix("--listen")
        }
        // A session spawned by another session is one session, not two.
        let livePIDs = Set(candidates.map(\.pid))
        candidates = candidates.filter { !livePIDs.contains($0.ppid) }

        let claudeActivity = phase("claude transcripts") { claudeActivityByCWD() }
        let runningApps = NSWorkspace.shared.runningApplications
        // Electron helpers are listed here too, and activating one of those does nothing.
        let appPIDs = Set(runningApps.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))

        var children: [pid_t: [pid_t]] = [:]
        for entry in processes.values where entry.ppid > 0 {
            children[entry.ppid, default: []].append(entry.pid)
        }

        var cpuNow: [pid_t: Double] = [:]
        var sessions: [Session] = []

        for proc in candidates {
            let cpu = table.subtreeCPUSeconds(proc.pid, children: children)
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
                key: "pid:\(proc.pid)",
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

        // A cursor-agent in a terminal writes a transcript too, so its folder is spoken for.
        let claimed = Set(sessions.filter { $0.agent == "Cursor Agent" }.compactMap(\.path))
        sessions.append(contentsOf: phase("cursor transcripts") { cursorSessions(excluding: claimed) })
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

        // A session has finished only after it stays quiet for several scans in a row.
        var states: [String: TrackState] = [:]
        for session in snapshot.sessions {
            var state = trackStates[session.key] ?? TrackState()
            if session.working {
                state.wasWorking = true
                state.quietScans = 0
                state.notified = false
            } else if state.wasWorking, !state.notified {
                state.quietScans += 1
                if state.quietScans >= idleConfirmScans {
                    state.notified = true
                    snapshot.wentIdle.append(session)
                }
            }
            states[session.key] = state   // sessions that vanish drop out of tracking
        }
        trackStates = states
        scanCount += 1
        snapshot.id = scanCount

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

    // MARK: Cursor chats

    /// Cursor runs its chats inside the app rather than as one process each, so there is
    /// nothing to find in the process table: a busy chat and an idle one look identical
    /// from outside. Each chat does keep a transcript, and a turn closes it with a
    /// turn_ended line, which is a far better signal than CPU ever was.
    private func cursorSessions(excluding claimed: Set<String>) -> [Session] {
        let root = NSHomeDirectory() + "/.cursor/projects"
        let cutoff = Date().addingTimeInterval(-cursorMidTurnWindow)
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }

        var sessions: [Session] = []
        for project in projects {
            let workspace = cursorWorkspace(project)
            if let workspace, claimed.contains(workspace) { continue }

            for file in recentTranscripts(in: root + "/" + project + "/agent-transcripts",
                                          newerThan: cutoff) {
                let working = !turnEnded(file.path, modified: file.modified)
                // Only a chat still mid-turn earns the longer window.
                guard working || Date().timeIntervalSince(file.modified) < cursorSessionWindow
                    else { continue }

                sessions.append(Session(
                    key: "cursor:" + (file.path as NSString).lastPathComponent,
                    agent: "Cursor Agent",
                    folder: workspace.map(shortPath) ?? "no folder",
                    path: workspace,
                    tty: nil,
                    subtitle: nil,
                    host: .cursorWorkspace(workspace),
                    working: working,
                    lastActivity: file.modified
                ))
            }
        }
        return sessions
    }

    /// The tail only needs re-reading once the file has grown.
    private func turnEnded(_ path: String, modified: Date) -> Bool {
        if let cached = turnEndedCache[path], cached.modified == modified { return cached.ended }
        let ended = lastLine(ofFile: path)?.contains("\"type\":\"turn_ended\"") ?? false
        turnEndedCache[path] = (modified, ended)
        return ended
    }

    /// Walking the filesystem to decode a name is not free, but a workspace never moves.
    private func cursorWorkspace(_ encoded: String) -> String? {
        if let cached = cursorWorkspaceCache[encoded] { return cached }
        let resolved = decodeWorkspace(encoded)
        cursorWorkspaceCache[encoded] = resolved
        return resolved
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
                key: "codex:\(rootID)",
                agent: "Codex",
                folder: shortPath(group.cwd),
                path: group.cwd,
                tty: nil,
                subtitle: group.subagents > 0 ? "\(group.subagents) subagent\(group.subagents == 1 ? "" : "s")" : nil,
                host: .codexThread(rootID),
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
    case .codexThread(let threadID):
        // ChatGPT registers the codex:// scheme and builds these links itself.
        guard let url = URL(string: "codex://threads/\(threadID)") else { return }
        NSWorkspace.shared.open(url)
    case .cursorWorkspace(let path):
        // Reopening a folder Cursor already has open raises that window instead of adding one.
        guard let path, let cursor = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: cursorBundleID) else {
            focus(.bundle(cursorBundleID))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: cursor, configuration: configuration)
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

// MARK: - Notifications

let notificationsEnabledKey = "NotifyWhenIdle"

/// Encodes where a session lives so a tapped notification can still focus it.
func encodeHost(_ host: HostTarget) -> [String: Any] {
    switch host {
    case .app(let pid, let tty):
        var info: [String: Any] = ["kind": "app", "pid": Int(pid)]
        if let tty { info["tty"] = tty }
        return info
    case .bundle(let bundleID): return ["kind": "bundle", "bundle": bundleID]
    case .codexThread(let id): return ["kind": "codex", "thread": id]
    case .cursorWorkspace(let path):
        var info: [String: Any] = ["kind": "cursor"]
        if let path { info["path"] = path }
        return info
    case .unknown: return ["kind": "unknown"]
    }
}

func decodeHost(_ info: [AnyHashable: Any]) -> HostTarget {
    switch info["kind"] as? String {
    case "app":
        guard let pid = info["pid"] as? Int else { return .unknown }
        return .app(pid: pid_t(pid), tty: info["tty"] as? String)
    case "bundle":
        return (info["bundle"] as? String).map { HostTarget.bundle($0) } ?? .unknown
    case "codex":
        return (info["thread"] as? String).map { HostTarget.codexThread($0) } ?? .unknown
    case "cursor":
        return .cursorWorkspace(info["path"] as? String)
    default:
        return .unknown
    }
}

// MARK: - Menu bar

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?

    var lastHandledScan = 0
    var pendingAlerts = 0

    var notificationsEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: notificationsEnabledKey) == nil { return true }
            return defaults.bool(forKey: notificationsEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "🧠"
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if CommandLine.arguments.contains("--notify-test") { runNotificationTest() }

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
            DispatchQueue.main.async {
                self.applyTitle(snapshot)
                self.announce(snapshot)
            }
        }
    }

    /// Snapshots carry an id so a cached one is never announced twice.
    func announce(_ snapshot: Snapshot) {
        guard snapshot.id > lastHandledScan else { return }
        lastHandledScan = snapshot.id
        guard notificationsEnabled, !snapshot.wentIdle.isEmpty else { return }
        // The badge is the one signal that cannot be blocked by notification permissions.
        pendingAlerts += snapshot.wentIdle.count
        applyTitle(snapshot)
        for session in snapshot.wentIdle { notify(session) }
    }

    func notify(_ session: Session) {
        let host = session.host.describedHost
        deliver(title: "\(session.agent) · \(session.folder)",
                body: host.isEmpty ? "Finished, waiting for you" : "Finished in \(host), waiting for you",
                host: session.host)
    }

    /// Prefers a real notification, which supports click-to-focus. That needs permission
    /// this app cannot always get: an ad-hoc signature has no stable identity, so macOS
    /// may refuse. AppleScript posts a banner without any permission, so it is the fallback.
    func deliver(title: String, body: String, host: HostTarget) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard allowed else {
                DispatchQueue.main.async { self.deliverViaAppleScript(title: title, body: body) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = encodeHost(host)
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func deliverViaAppleScript(title: String, body: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "display notification \(quoted(body)) with title \(quoted(title)) sound name \"Ping\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        focus(decodeHost(response.notification.request.content.userInfo))
        completionHandler()
    }

    @objc func toggleNotifications(_ sender: NSMenuItem) {
        notificationsEnabled.toggle()
    }

    @objc func sendTestNotification(_ sender: NSMenuItem) {
        deliver(title: "Session Tracker",
                body: "Test notification. This is what a finished session looks like.",
                host: .unknown)
    }

    /// Must run inside a launched app: asking the notification centre anything before
    /// NSApplication exists fails with "Notifications are not allowed for this application".
    func runNotificationTest() {
        let logPath = "/tmp/session-tracker-notify-test.log"
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        func report(_ message: String) {
            print(message)
            guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((message + "\n").utf8))
            try? handle.close()
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            report("authorization: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            center.getNotificationSettings { settings in
                let allowed = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                report("status=\(settings.authorizationStatus.rawValue) → using \(allowed ? "UserNotifications" : "AppleScript fallback")")
                DispatchQueue.main.async {
                    self.deliver(title: "Session Tracker",
                                 body: "Test notification. If you can read this, alerts work.",
                                 host: .unknown)
                    report("posted")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
                }
            }
        }
    }

    func applyTitle(_ snapshot: Snapshot) {
        let working = snapshot.sessions.filter(\.working).count
        let total = snapshot.sessions.count
        let icon = pendingAlerts > 0 ? "🔔" : "🧠"
        if total == 0 {
            statusItem.button?.title = icon
        } else {
            statusItem.button?.title = working > 0 ? "\(icon) \(working)/\(total)" : "\(icon) \(total)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = Scanner.shared.snapshot(maxAge: 2)
        pendingAlerts = 0   // opening the menu is how you acknowledge the badge
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
        let toggle = NSMenuItem(title: "Notify when a session finishes",
                                action: #selector(toggleNotifications(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = notificationsEnabled ? .on : .off
        menu.addItem(toggle)

        let test = NSMenuItem(title: "Send test notification",
                              action: #selector(sendTestNotification(_:)), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        applyTitle(snapshot)
        announce(snapshot)
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
        var host = session.host.describedHost
        if case .codexThread(let id) = session.host { host += " thread \(id)" }
        print("  \(session.dot) \(session.agent) · \(session.folder)\(subtitle)  [\(session.statusText)]  focus→ \(host.isEmpty ? "unknown" : host)")
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
