import Darwin
import Foundation

/// One linked worktree (or orphan folder) as the Git Worktrees category
/// shows it. Carried on its CleanableItem so the clean step knows which
/// repository to run `git worktree remove` in.
struct GitWorktreeReport: Equatable {
    let path: String
    /// Main repository; nil for an orphan whose repository is unknown.
    let repositoryPath: String?
    let branch: String?
    let head: String?
    let verdict: GitWorktreeSupport.Verdict
    let lastActivity: Date?

    var displayName: String {
        let repo = repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        let ref = branch ?? head.map { String($0.prefix(8)) } ?? URL(fileURLWithPath: path).lastPathComponent
        return "\(repo) · \(ref)"
    }
}

/// Finds git worktrees left behind by AI coding agents and gathers the
/// signals GitWorktreeSupport.classify needs. Read-only except for
/// `remove`, which only ever runs `git worktree remove` without --force.
struct GitWorktreeScanner {
    let homeDirectory: String
    let gitPath: String
    var inactiveDays = GitWorktreeSupport.defaultInactiveDays
    /// Extra paths to resolve to repositories (tests, user roots later).
    var repositoryHints: [String] = []
    /// Replaces the libproc lookup of process working directories (tests).
    var workingDirectories: (() -> [String])?

    private let timeout: TimeInterval = 20
    private var fileManager: FileManager { .default }

    init(homeDirectory: String, gitPath: String) {
        self.homeDirectory = homeDirectory
        self.gitPath = gitPath
    }

    /// Homebrew git first; /usr/bin/git only when developer tools are
    /// installed, because the shim otherwise pops Apple's CLT installer.
    static func locateGit(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        developerToolsInstalled: () -> Bool = { SimulatorRuntimeSupport.isXcrunAvailable() }
    ) -> String? {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where isExecutable(candidate) {
            return candidate
        }
        if isExecutable("/usr/bin/git"), developerToolsInstalled() {
            return "/usr/bin/git"
        }
        return nil
    }

    // MARK: - Scan

    func scan() async -> [GitWorktreeReport] {
        let cwdPaths = (workingDirectories ?? Self.processWorkingDirectories)()
        let agentCandidates = agentWorktreeCandidates()
        var hints = GitWorktreeSupport.claudeProjectPaths(fromClaudeJSON: claudeJSON()) + repositoryHints
        hints.append(contentsOf: agentCandidates)

        var repositories: [String] = []
        for hint in hints where fileManager.fileExists(atPath: hint) {
            if Task.isCancelled { return [] }
            guard let repo = await mainRepository(containing: hint), !repositories.contains(repo) else { continue }
            repositories.append(repo)
        }

        var reports: [GitWorktreeReport] = []
        var listedPaths: Set<String> = []
        var orphanCandidates = Set(agentCandidates.map(Self.canonical))
        for repo in repositories {
            if Task.isCancelled { return reports }
            let listed = await listWorktrees(in: repo)
            listedPaths.formUnion(listed.map { Self.canonical($0.path) })
            orphanCandidates.formUnion(claudeWorktreeFolders(in: repo))
            let base = await baseRef(in: repo)
            for worktree in listed.dropFirst() where !worktree.isBare {
                if Task.isCancelled { return reports }
                reports.append(await inspect(worktree, repository: repo, baseRef: base, cwdPaths: cwdPaths))
            }
        }

        for orphan in orphanCandidates.subtracting(listedPaths).sorted() {
            reports.append(GitWorktreeReport(
                path: orphan,
                repositoryPath: nil,
                branch: nil,
                head: nil,
                verdict: GitWorktreeSupport.Verdict(status: .orphan, reasons: [.notListedByGit]),
                lastActivity: Self.modificationDate(orphan)
            ))
        }
        return reports
    }

    /// Fresh verdict for one worktree right before it is removed, so a
    /// change since the scan (new edits, a lock, an agent starting work in
    /// it) is caught. Nil when git no longer lists the path.
    func reinspect(path: String, repository: String) async -> GitWorktreeReport? {
        let target = Self.canonical(path)
        guard let listed = await listWorktrees(in: repository).dropFirst().first(where: { Self.canonical($0.path) == target })
        else { return nil }
        let cwdPaths = (workingDirectories ?? Self.processWorkingDirectories)()
        return await inspect(listed, repository: repository, baseRef: await baseRef(in: repository), cwdPaths: cwdPaths)
    }

    /// `git worktree remove <path>` (never --force: git refuses dirty or
    /// locked worktrees and its message is returned), then
    /// `git worktree prune` for the repository.
    func remove(path: String, repository: String) async -> String? {
        guard let result = await git(["worktree", "remove", path], in: repository) else {
            return "git worktree remove did not finish"
        }
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "git worktree remove failed (exit \(result.status))" : detail
        }
        _ = await git(["worktree", "prune"], in: repository)
        return nil
    }

    // MARK: - Signals

    private func inspect(
        _ listed: GitWorktreeSupport.ListedWorktree,
        repository: String,
        baseRef: String?,
        cwdPaths: [String]
    ) async -> GitWorktreeReport {
        var signals = GitWorktreeSupport.Signals(listed: listed)
        let path = listed.path
        signals.isAgentWorktree = GitWorktreeSupport.isAgentWorktreePath(path, homeDirectory: homeDirectory)
        let canonicalPath = Self.canonical(path)
        signals.inUse = cwdPaths.contains { GitWorktreeSupport.isInside(Self.canonical($0), root: canonicalPath) }

        if !listed.isPrunable {
            if let status = await git(["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching"], in: path),
               status.status == 0 {
                signals.status = GitWorktreeSupport.parseStatus(status.stdout)
            } else {
                // Unreadable status is treated as uncommitted work.
                signals.status.trackedChanges = max(signals.status.trackedChanges, 1)
            }
            if let stash = await git(["stash", "list", "--format=%P%x00%gs%x00"], in: repository), stash.status == 0 {
                signals.hasAttributedStash = GitWorktreeSupport.hasAttributedStash(stash.stdout, branch: listed.branch, head: listed.head)
            }
            var uniqueArgs = ["rev-list", "--count", "HEAD", "--not"]
            if let branch = listed.branch { uniqueArgs.append("--exclude=\(branch)") }
            uniqueArgs.append(contentsOf: ["--branches", "--remotes"])
            if let unique = await git(uniqueArgs, in: path), unique.status == 0 {
                signals.uniqueCommits = Int(unique.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            } else {
                signals.uniqueCommits = 1
            }
            signals.baseRef = baseRef
            if let baseRef {
                let ancestor = await git(["merge-base", "--is-ancestor", "HEAD", baseRef], in: path)
                signals.isAncestorOfBase = ancestor?.status == 0
                if !signals.isAncestorOfBase, let cherry = await git(["cherry", baseRef, "HEAD"], in: path), cherry.status == 0 {
                    signals.cherryAllApplied = GitWorktreeSupport.cherryAllApplied(cherry.stdout)
                }
            }
            if let reflog = await git(["reflog", "show", "--format=%gs", "HEAD"], in: path), reflog.status == 0 {
                signals.hadOwnWork = GitWorktreeSupport.reflogShowsOwnWork(reflog.stdout)
            }
            signals.lastActivity = await lastActivity(of: path)
        }

        return GitWorktreeReport(
            path: path,
            repositoryPath: repository,
            branch: listed.branch,
            head: listed.head,
            verdict: GitWorktreeSupport.classify(signals, inactiveDays: inactiveDays),
            lastActivity: signals.lastActivity
        )
    }

    /// Most recent of: worktree folder mtime, its admin files under
    /// <repo>/.git/worktrees/<name>, the HEAD commit date, and the newest
    /// file found by a capped walk that skips build artifacts.
    private func lastActivity(of path: String) async -> Date? {
        var dates: [Date] = []
        if let date = Self.modificationDate(path) { dates.append(date) }
        if let adminDir = gitAdminDirectory(ofWorktree: path) {
            for name in ["HEAD", "index", "logs/HEAD"] {
                if let date = Self.modificationDate((adminDir as NSString).appendingPathComponent(name)) { dates.append(date) }
            }
        }
        if let log = await git(["log", "-1", "--format=%ct", "HEAD"], in: path), log.status == 0,
           let seconds = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        if let newest = newestFileDate(under: path) { dates.append(newest) }
        return dates.max()
    }

    private static let walkSkippedNames: Set<String> = [
        ".git", "node_modules", ".next", "build", "dist", "DerivedData", ".build", "target", ".venv", "venv", "__pycache__",
    ]

    private func newestFileDate(under path: String, limit: Int = 20_000) -> Date? {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var newest: Date?
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit || Task.isCancelled { break }
            if Self.walkSkippedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return newest
    }

    // MARK: - Discovery

    private func claudeJSON() -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: "\(homeDirectory)/.claude.json"))) ?? Data()
    }

    /// Folders with a `.git` entry under ~/.cursor/worktrees and
    /// ~/.codex/worktrees, up to three levels deep.
    private func agentWorktreeCandidates() -> [String] {
        var found: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth <= 3, let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries.sorted() {
                let child = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue,
                      !Self.isSymlink(child) else { continue }
                if fileManager.fileExists(atPath: (child as NSString).appendingPathComponent(".git")) {
                    found.append(child)
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        for root in GitWorktreeSupport.globalAgentWorktreeRoots(homeDirectory: homeDirectory) {
            walk(root, depth: 1)
        }
        return found
    }

    /// Direct children of <repo>/.claude/worktrees that look like worktrees.
    private func claudeWorktreeFolders(in repository: String) -> [String] {
        let root = (repository as NSString).appendingPathComponent(".claude/worktrees")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return entries.compactMap { entry in
            let child = (root as NSString).appendingPathComponent(entry)
            guard !Self.isSymlink(child),
                  fileManager.fileExists(atPath: (child as NSString).appendingPathComponent(".git"))
            else { return nil }
            return Self.canonical(child)
        }
    }

    private func mainRepository(containing path: String) async -> String? {
        guard let result = await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path),
              result.status == 0,
              let repo = GitWorktreeSupport.mainRepository(forCommonDir: result.stdout)
        else { return nil }
        return Self.canonical(repo)
    }

    private func listWorktrees(in repository: String) async -> [GitWorktreeSupport.ListedWorktree] {
        guard let result = await git(["worktree", "list", "--porcelain", "-z"], in: repository), result.status == 0
        else { return [] }
        return GitWorktreeSupport.parseWorktreeList(result.stdout)
    }

    /// origin/HEAD, else origin/main, origin/master, main, master.
    private func baseRef(in repository: String) async -> String? {
        if let head = await git(["rev-parse", "--abbrev-ref", "origin/HEAD"], in: repository), head.status == 0 {
            let ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty, ref != "origin/HEAD" { return ref }
        }
        for candidate in ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"] {
            if let verify = await git(["rev-parse", "--verify", "--quiet", candidate], in: repository), verify.status == 0 {
                return candidate
            }
        }
        return nil
    }

    private func gitAdminDirectory(ofWorktree path: String) -> String? {
        guard let contents = try? String(contentsOfFile: (path as NSString).appendingPathComponent(".git"), encoding: .utf8),
              contents.hasPrefix("gitdir:")
        else { return nil }
        let dir = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.hasPrefix("/") ? dir : (path as NSString).appendingPathComponent(dir)
    }

    // MARK: - Process helpers

    private struct GitResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func git(_ arguments: [String], in directory: String) async -> GitResult? {
        var environment = ProcessInfo.processInfo.environment
        // Read-only commands must not take index.lock in a worktree an agent
        // may be using right now.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        do {
            let output = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: gitPath),
                // A repository's own config must not run commands for us.
                arguments: ["-c", "core.fsmonitor=false", "-C", directory] + arguments,
                timeout: timeout,
                environment: environment
            )
            return GitResult(
                status: output.status,
                stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                stderr: String(data: output.stderr, encoding: .utf8) ?? ""
            )
        } catch {
            if !(error is CancellationError) {
                Logger.shared.log("git \(arguments.first ?? "") in \(directory) failed: \(error.localizedDescription)", level: .warning)
            }
            return nil
        }
    }

    /// Current working directory of every process this user can inspect.
    static func processWorkingDirectories() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let capacityBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, capacityBytes) }
        guard count > 0 else { return [] }
        var paths: [String] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    // MARK: - File helpers

    /// realpath(3), so /var/… and /private/var/… compare equal the way git
    /// prints them. Falls back to the standardized path.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    private static func isSymlink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType) == .typeSymbolicLink
    }
}
