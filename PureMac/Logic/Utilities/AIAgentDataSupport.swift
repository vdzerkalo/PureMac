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
        /// as the owner running. Matching by path (not by name) keeps a
        /// terminal `claude` CLI session from blocking Claude Desktop rows.
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
        /// A non-empty regular file with this name in the same directory.
        case siblingFile(String)
        /// A real directory at this path relative to home.
        case directory([String])
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

    /// The complete allowlist. Adding an entry here is the only way to make a
    /// path removable by this category.
    static let rules: [Rule] = [
        Rule(
            id: "claude.vm.rootfs",
            owner: .claudeDesktop,
            components: appSupport.map(Component.literal)
                + [.literal("Claude"), .literal("vm_bundles"), .literal("claudevm.bundle"), .literal("rootfs.img")],
            isDirectory: false,
            requirements: [.siblingFile("rootfs.img.zst")],
            title: { _ in String(localized: "Claude Desktop VM disk image") },
            detail: {
                String(localized: "Root disk of the Claude Desktop VM. The compressed copy rootfs.img.zst stays next to it. Session data is a separate file and is not touched.")
            }
        ),
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
            requirements: [],
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
            requirements: [.directory([".gemini", "antigravity", "browser_recordings"])],
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
        case ownerRunning(Owner)

        var description: String {
            switch self {
            case .notAllowlisted: return "path is not an allowlisted AI agent data location"
            case .forbiddenLocation: return "path is in a protected agent location"
            case .missing: return "path no longer exists"
            case .symlink: return "path or a parent is a symbolic link"
            case .unexpectedType: return "path is not the expected file type"
            case .missingRequirement: return "the regeneration source is missing"
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
    /// home, the expected file type, and the regeneration requirements. Does
    /// not look at running processes; use `validateForRemoval`.
    static func validate(
        path: String,
        homeDirectory: URL,
        fileManager: FileManager = .default
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
            case .siblingFile(let name):
                let sibling = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: sibling),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
                    return .failure(.missingRequirement)
                }
            case .directory(let relative):
                // Every component must be a real directory, like the item itself.
                var target = home
                for name in relative {
                    target = (target as NSString).appendingPathComponent(name)
                    guard isRealDirectory(target, fileManager: fileManager) else {
                        return .failure(.missingRequirement)
                    }
                }
            }
        }
        return .success(Validated(rule: rule, url: URL(fileURLWithPath: path)))
    }

    /// Validation plus the running-app check. Call it again immediately before
    /// the Trash move: both results must agree.
    static func validateForRemoval(
        path: String,
        homeDirectory: URL,
        isOwnerRunning: OwnerRunningCheck,
        fileManager: FileManager = .default
    ) -> Result<Validated, Refusal> {
        switch validate(path: path, homeDirectory: homeDirectory, fileManager: fileManager) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let validated):
            if isOwnerRunning(validated.owner) { return .failure(.ownerRunning(validated.owner)) }
            return .success(validated)
        }
    }

    // MARK: - Running apps

    /// Live check: bundle identifier of a running app, or any process whose
    /// executable is under one of the owner's path prefixes. Fails closed when
    /// the process list cannot be read.
    static func liveOwnerRunningCheck(homeDirectory: URL) -> OwnerRunningCheck {
        let home = canonicalHomeDirectory(homeDirectory).path
        return { owner in
            for identifier in owner.bundleIdentifiers
            where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                return true
            }
            return anyProcess(withExecutablePrefixes: owner.executablePathPrefixes(home: home))
        }
    }

    static func anyProcess(withExecutablePrefixes prefixes: [String]) -> Bool {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return true }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(min(Int(filled), pids.count)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let executable = String(cString: buffer)
            if prefixes.contains(where: { executable.hasPrefix($0) }) { return true }
        }
        return false
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
