import AppKit
import Darwin
import Foundation

/// Discovery and safety policy for the review-only "AI Agent Data" category.
///
/// Every removable shape is an exact path template below the home directory
/// (see `rules`). There is no prefix matching: a path is either one of the
/// templates or it is refused. Credentials, history, sessions and settings of
/// the agent apps are never templated, and anything under `~/.claude` or
/// `~/.claude.json` is refused unconditionally. Removal is Move to Trash only,
/// and only while the owning app is not running.
///
/// Evidence for each template is in docs/AI-AGENT-DATA.md.
enum AIAgentDataSupport {
    // MARK: - Owners

    /// The app that owns a path. A running owner blocks removal.
    enum Owner: String, CaseIterable, Hashable {
        case claudeDesktop
        case codex
        case antigravity
        case cursor

        var displayName: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .codex: return "Codex"
            case .antigravity: return "Antigravity"
            case .cursor: return "Cursor"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .claudeDesktop: return ["com.anthropic.claudefordesktop"]
            case .codex: return ["com.openai.codex"]
            case .antigravity: return ["com.google.antigravity"]
            case .cursor: return ["com.todesktop.230313mzl4w4u92"]
            }
        }

        /// A process whose executable lives under one of these prefixes counts
        /// as the owner running. The `claude` CLI that Claude Desktop manages
        /// under `~/Library/Application Support/Claude/` therefore blocks
        /// Claude Desktop rows; a Claude Code CLI installed elsewhere does not.
        func executablePathPrefixes(home: String) -> [String] {
            switch self {
            case .claudeDesktop:
                return ["/Applications/Claude.app/", "\(home)/Library/Application Support/Claude/"]
            case .codex:
                return ["/Applications/ChatGPT.app/", "/Applications/Codex.app/", "\(home)/.codex/"]
            case .antigravity:
                return ["/Applications/Antigravity.app/", "\(home)/.gemini/"]
            case .cursor:
                return ["/Applications/Cursor.app/", "\(home)/.cursor/"]
            }
        }

        /// Substrings of an executable path that identify the owner wherever it
        /// is installed. Codex also runs as a CLI from Homebrew, npm or nvm
        /// trees (`.../node_modules/@openai/codex/...`) under a `node` parent.
        var executablePathFragments: [String] {
            switch self {
            case .codex: return ["/@openai/codex"]
            default: return []
            }
        }

        /// Executable file names (last path component) that identify the owner.
        var executableNames: [String] {
            switch self {
            case .codex: return ["codex"]
            default: return []
            }
        }

        /// Process names used when a process's executable path cannot be read:
        /// a name starting with one of these (case-insensitive) counts as running.
        var processNamePrefixes: [String] {
            switch self {
            case .claudeDesktop: return ["Claude"]
            case .codex: return ["Codex"]
            case .antigravity: return ["Antigravity"]
            case .cursor: return ["Cursor"]
            }
        }

        func matches(_ process: ProcessEntry, home: String) -> Bool {
            if let path = process.path {
                if executablePathPrefixes(home: home).contains(where: { path.hasPrefix($0) }) { return true }
                if executablePathFragments.contains(where: { path.contains($0) }) { return true }
                return executableNames.contains((path as NSString).lastPathComponent)
            }
            // Path unreadable: fall back to the process name and fail closed
            // when it looks like the owner.
            guard let name = process.name?.lowercased() else { return false }
            return processNamePrefixes.contains { name.hasPrefix($0.lowercased()) }
        }
    }

    /// One running process as seen by the probe.
    struct ProcessEntry: Equatable {
        let path: String?
        let name: String?
    }

    /// Returns true when the owner is running. Injected by tests.
    typealias OwnerRunningCheck = (Owner) -> Bool

    // MARK: - Rules

    enum Component: Equatable {
        case literal(String)
        /// Lowercase hex identifier, 8 to 64 characters.
        case hexIdentifier
        /// `prefix` followed by exactly `length` ASCII letters or digits.
        case randomSuffix(prefix: String, length: Int)

        func matches(_ name: String) -> Bool {
            switch self {
            case .literal(let expected):
                return name == expected
            case .hexIdentifier:
                return (8...64).contains(name.utf8.count)
                    && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
            case .randomSuffix(let prefix, let length):
                guard name.hasPrefix(prefix) else { return false }
                let tail = name.dropFirst(prefix.count)
                return tail.utf8.count == length
                    && tail.utf8.allSatisfy {
                        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                    }
            }
        }
    }

    /// A condition that must hold for the item to count as regenerable.
    enum Requirement {
        /// A real directory at this path relative to home.
        case directory([String])
        /// Every top-level entry name of the item exists, as a non-symlink, in
        /// the real directory at this path relative to home (names only).
        case entriesExist(in: [String])
        /// Nothing (not even a symlink) exists at this path relative to home.
        case noFile([String])
        /// The item's own modification date is at least this old.
        case olderThan(TimeInterval)
    }

    struct Rule {
        let id: String
        let owner: Owner
        /// Path below home. Each component is checked against the real name.
        let components: [Component]
        let isDirectory: Bool
        let requirements: [Requirement]
        let title: (String) -> String
        let detail: () -> String
    }

    private static let appSupport = ["Library", "Application Support"]
    /// A Codex plugin backup younger than this may belong to a sync in progress.
    static let pluginBackupMinimumAge: TimeInterval = 60 * 60

    /// The complete allowlist. Adding an entry here is the only way to make a
    /// path removable by this category.
    static let rules: [Rule] = [
        Rule(
            id: "claude.simulator.deriveddata",
            owner: .claudeDesktop,
            components: appSupport.map(Component.literal)
                + [.literal("Claude"), .literal("simulator-builds"), .hexIdentifier, .literal("DerivedData")],
            isDirectory: true,
            requirements: [],
            title: { _ in String(localized: "Claude iOS Simulator build output") },
            detail: {
                String(localized: "Xcode build output of Claude's iOS Simulator tool. Rebuilt on the next simulator build.")
            }
        ),
        Rule(
            id: "claude.cache",
            owner: .claudeDesktop,
            components: appSupport.map(Component.literal) + [.literal("Claude"), .literal("Cache")],
            isDirectory: true,
            requirements: [],
            title: { _ in String(localized: "Claude Desktop web cache") },
            detail: { String(localized: "Chromium HTTP cache of Claude Desktop. Rebuilt automatically.") }
        ),
        Rule(
            id: "claude.codecache",
            owner: .claudeDesktop,
            components: appSupport.map(Component.literal) + [.literal("Claude"), .literal("Code Cache")],
            isDirectory: true,
            requirements: [],
            title: { _ in String(localized: "Claude Desktop code cache") },
            detail: { String(localized: "Chromium compiled-script cache of Claude Desktop. Rebuilt automatically.") }
        ),
        Rule(
            id: "codex.pluginbackup",
            owner: .codex,
            components: [.literal(".codex"), .literal(".tmp"), .randomSuffix(prefix: "plugins-backup-", length: 6)],
            isDirectory: true,
            requirements: [.noFile([".codex", ".tmp", "plugins.sync.lock"]), .olderThan(pluginBackupMinimumAge)],
            title: { name in String(format: String(localized: "Codex plugin backup %@"), name) },
            detail: {
                String(localized: "Old copy of Codex's plugin folder left by a plugin sync. The current plugins are kept elsewhere.")
            }
        ),
        Rule(
            id: "antigravity.backup.recordings",
            owner: .antigravity,
            components: [.literal(".gemini"), .literal("antigravity-backup"), .literal("browser_recordings")],
            isDirectory: true,
            requirements: [
                .directory([".gemini", "antigravity", "browser_recordings"]),
                .entriesExist(in: [".gemini", "antigravity", "browser_recordings"]),
            ],
            title: { _ in String(localized: "Antigravity backup: browser recordings") },
            detail: {
                String(localized: "Frames of agent browser sessions inside the one-time backup. The live recordings stay in ~/.gemini/antigravity. Backup settings are not touched.")
            }
        ),
        Rule(
            id: "cursor.vsix",
            owner: .cursor,
            components: appSupport.map(Component.literal) + [.literal("Cursor"), .literal("CachedExtensionVSIXs")],
            isDirectory: true,
            requirements: [],
            title: { _ in String(localized: "Cursor extension download cache") },
            detail: { String(localized: "Downloaded extension packages (.vsix). Downloaded again when needed.") }
        ),
    ]

    // MARK: - Refusals

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAllowlisted
        case forbiddenLocation
        case missing
        case symlink
        case unexpectedType
        case missingRequirement
        case syncInProgress
        case tooRecent
        case notDuplicate
        case ownerRunning(Owner)

        var description: String {
            switch self {
            case .notAllowlisted: return "path is not an allowlisted AI agent data location"
            case .forbiddenLocation: return "path is in a protected agent location"
            case .missing: return "path no longer exists"
            case .symlink: return "path or a parent is a symbolic link"
            case .unexpectedType: return "path is not the expected file type"
            case .missingRequirement: return "the live copy it duplicates is missing"
            case .syncInProgress: return "a sync lock file exists"
            case .tooRecent: return "it was modified less than an hour ago"
            case .notDuplicate: return "it holds entries that the live copy does not"
            case .ownerRunning(let owner): return "\(owner.displayName) is running"
            }
        }
    }

    struct Validated {
        let rule: Rule
        let url: URL
        var owner: Owner { rule.owner }
    }

    struct Candidate {
        let rule: Rule
        let url: URL
        let name: String
        let lastModified: Date?
    }

    // MARK: - Public API

    static func canonicalHomeDirectory(_ homeDirectory: URL) -> URL {
        XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeDirectory)
    }

    /// Lists existing, structurally valid candidates. Sizes are measured by the
    /// caller. Wildcard components are expanded by listing real directories only.
    static func discover(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        let home = canonicalHomeDirectory(homeDirectory)
        var candidates: [Candidate] = []
        for rule in rules {
            var paths = [home.path]
            for component in rule.components {
                var next: [String] = []
                for base in paths {
                    switch component {
                    case .literal(let name):
                        next.append((base as NSString).appendingPathComponent(name))
                    case .hexIdentifier, .randomSuffix:
                        guard isRealDirectory(base, fileManager: fileManager),
                              let names = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
                        for name in names.sorted() where component.matches(name) {
                            next.append((base as NSString).appendingPathComponent(name))
                        }
                    }
                }
                paths = next
            }
            for path in paths {
                guard case .success(let validated) = validate(
                    path: path,
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                ) else { continue }
                let attributes = try? fileManager.attributesOfItem(atPath: path)
                candidates.append(Candidate(
                    rule: validated.rule,
                    url: validated.url,
                    name: rule.title((path as NSString).lastPathComponent),
                    lastModified: attributes?[.modificationDate] as? Date
                ))
            }
        }
        return candidates
    }

    /// The rule a path matches by shape alone (no filesystem access).
    static func rule(
        forPath path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Rule? {
        guard let names = relativeComponents(of: path, home: canonicalHomeDirectory(homeDirectory).path) else {
            return nil
        }
        return rules.first { rule in
            rule.components.count == names.count
                && zip(rule.components, names).allSatisfy { $0.matches($1) }
        }
    }

    static func detail(
        forPath path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        rule(forPath: path, homeDirectory: homeDirectory)?.detail()
    }

    /// Structural validation: allowlisted shape, no symlink anywhere below
    /// home, the expected file type, and the rule requirements. Does
    /// not look at running processes; use `validateForRemoval`.
    static func validate(
        path: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> Result<Validated, Refusal> {
        let home = canonicalHomeDirectory(homeDirectory).path
        guard !path.utf8.contains(0), path == (path as NSString).standardizingPath else {
            return .failure(.notAllowlisted)
        }
        if isProtectedAgentLocation(path, home: home) { return .failure(.forbiddenLocation) }
        guard let names = relativeComponents(of: path, home: home) else {
            return .failure(.notAllowlisted)
        }
        guard let rule = rules.first(where: { rule in
            rule.components.count == names.count
                && zip(rule.components, names).allSatisfy { $0.matches($1) }
        }) else {
            return .failure(.notAllowlisted)
        }

        var current = home
        for (index, name) in names.enumerated() {
            current = (current as NSString).appendingPathComponent(name)
            guard let type = (try? fileManager.attributesOfItem(atPath: current))?[.type] as? FileAttributeType else {
                return .failure(.missing)
            }
            if type == .typeSymbolicLink { return .failure(.symlink) }
            let isLast = index == names.count - 1
            if isLast {
                let expected: FileAttributeType = rule.isDirectory ? .typeDirectory : .typeRegular
                guard type == expected else { return .failure(.unexpectedType) }
            } else if type != .typeDirectory {
                return .failure(.unexpectedType)
            }
        }
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            return .failure(.symlink)
        }

        for requirement in rule.requirements {
            switch requirement {
            case .directory(let relative):
                // Every component must be a real directory, like the item itself.
                var target = home
                for name in relative {
                    target = (target as NSString).appendingPathComponent(name)
                    guard isRealDirectory(target, fileManager: fileManager) else {
                        return .failure(.missingRequirement)
                    }
                }
            case .entriesExist(let relative):
                let live = relative.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
                guard let names = try? fileManager.contentsOfDirectory(atPath: path) else {
                    return .failure(.missing)
                }
                for name in names {
                    let counterpart = (live as NSString).appendingPathComponent(name)
                    guard let type = (try? fileManager.attributesOfItem(atPath: counterpart))?[.type] as? FileAttributeType,
                          type != .typeSymbolicLink else {
                        return .failure(.notDuplicate)
                    }
                }
            case .noFile(let relative):
                let target = relative.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
                if (try? fileManager.attributesOfItem(atPath: target)) != nil {
                    return .failure(.syncInProgress)
                }
            case .olderThan(let age):
                guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= age else {
                    return .failure(.tooRecent)
                }
            }
        }
        return .success(Validated(rule: rule, url: URL(fileURLWithPath: path)))
    }

    /// Validation plus the running-app check. Call it immediately before the
    /// Trash move; the scan-time validation is not enough.
    static func validateForRemoval(
        path: String,
        homeDirectory: URL,
        isOwnerRunning: OwnerRunningCheck,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> Result<Validated, Refusal> {
        switch validate(path: path, homeDirectory: homeDirectory, fileManager: fileManager, now: now) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let validated):
            if isOwnerRunning(validated.owner) { return .failure(.ownerRunning(validated.owner)) }
            return .success(validated)
        }
    }

    // MARK: - Running apps

    /// Live check: bundle identifier of a running app, or any process that
    /// `Owner.matches` accepts. Fails closed when the process list cannot be
    /// read. A process whose path cannot be read is matched by name; a process
    /// of another user whose path and name are both unreadable is ignored.
    static func liveOwnerRunningCheck(homeDirectory: URL) -> OwnerRunningCheck {
        let home = canonicalHomeDirectory(homeDirectory).path
        return { owner in
            for identifier in owner.bundleIdentifiers
            where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                return true
            }
            guard let processes = liveProcesses() else { return true }
            return processes.contains { owner.matches($0, home: home) }
        }
    }

    /// Owners that are running right now, from one process listing.
    static func liveRunningOwners(homeDirectory: URL) -> Set<Owner> {
        let home = canonicalHomeDirectory(homeDirectory).path
        let processes = liveProcesses()
        return Set(Owner.allCases.filter { owner in
            owner.bundleIdentifiers.contains {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            } || (processes.map { list in list.contains { owner.matches($0, home: home) } } ?? true)
        })
    }

    /// Nil when the process list itself cannot be read.
    static func liveProcesses() -> [ProcessEntry]? {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var entries: [ProcessEntry] = []
        for pid in pids.prefix(min(Int(filled), pids.count)) where pid > 0 {
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : nil
            var name: String?
            if path == nil {
                let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                if nameLength > 0 { name = String(cString: nameBuffer) }
            }
            if path != nil || name != nil { entries.append(ProcessEntry(path: path, name: name)) }
        }
        return entries
    }

    // MARK: - Helpers

    /// Never produced and never removable, whatever else matches.
    static func isProtectedAgentLocation(_ path: String, home: String) -> Bool {
        for protected in [".claude", ".claude.json"] {
            let root = (home as NSString).appendingPathComponent(protected)
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    private static func relativeComponents(of path: String, home: String) -> [String]? {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        let names = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !names.isEmpty, !names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return names
    }

    private static func isRealDirectory(_ path: String, fileManager: FileManager) -> Bool {
        guard let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory
    }
}
