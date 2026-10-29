import Foundation

/// Parsing + classification policy for the Git Worktrees category.
/// Kept free of Process I/O so unit tests can cover every status rule
/// without spawning git. GitWorktreeScanner gathers the signals.
///
/// A worktree is never judged by its folder name: every verdict comes from
/// what git reports about it, and anything that could hold work nobody has
/// saved elsewhere is Protected.
enum GitWorktreeSupport {
    /// Worktrees untouched for fewer days than this are only "Needs review".
    static let defaultInactiveDays = 7
    /// Agent worktrees active this recently are Protected whatever the
    /// inactivity setting: an idle Claude Code / Cursor / Codex session
    /// often has no process whose working directory is inside it.
    static let recentAgentActivityWindow: TimeInterval = 24 * 60 * 60

    /// Folder names that hold regenerable build output. The one list behind
    /// the "artifacts X · code Y" size split and the activity walk. Keep it
    /// in sync with `Purger.artifactNames` in cli/Sources/puremac/Core/Purger.swift:
    /// every name here must be there too, except `artifactNamesOnlyHere`
    /// (checked by GitWorktreeArtifactListTests).
    static let artifactDirectoryNames: Set<String> = [
        "node_modules", ".next", "build", "dist", "DerivedData", ".build", "target", ".venv", "venv", "__pycache__",
    ]
    /// Names the CLI's project purger leaves out because they are too
    /// generic there. Inside a worktree git settles whether a folder is
    /// ignored build output, so they are counted here.
    static let artifactNamesOnlyHere: Set<String> = ["build", "dist"]

    // MARK: - git worktree list --porcelain -z

    struct ListedWorktree: Equatable {
        let path: String
        var head: String?
        /// Short branch name ("feature/x"); nil when detached.
        var branch: String?
        var isBare = false
        var isDetached = false
        /// Lock reason; "" when locked without one, nil when not locked.
        var lockReason: String?
        /// Prunable reason; nil when git still finds the worktree.
        var prunableReason: String?

        var isLocked: Bool { lockReason != nil }
        var isPrunable: Bool { prunableReason != nil }
    }

    /// Parse `git worktree list --porcelain -z`. Records are NUL-separated
    /// attribute lists ended by an empty field. The first record is the main
    /// worktree; callers drop it.
    static func parseWorktreeList(_ output: String) -> [ListedWorktree] {
        var worktrees: [ListedWorktree] = []
        var current: ListedWorktree?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let finished = current { worktrees.append(finished) }
                current = nil
                continue
            }
            let (key, value) = splitAttribute(field)
            if key == "worktree" {
                if let finished = current { worktrees.append(finished) }
                current = ListedWorktree(path: value ?? "")
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.lockReason = value ?? ""
            case "prunable": current?.prunableReason = value ?? ""
            default: break
            }
        }
        if let finished = current { worktrees.append(finished) }
        return worktrees.filter { !$0.path.isEmpty }
    }

    private static func splitAttribute(_ field: Substring) -> (String, String?) {
        guard let space = field.firstIndex(of: " ") else { return (String(field), nil) }
        return (String(field[..<space]), String(field[field.index(after: space)...]))
    }

    // MARK: - git status --porcelain=v2 -z

    struct WorkingTreeStatus: Equatable {
        var trackedChanges = 0
        var untracked: [String] = []
        var ignored: [String] = []

        /// Ignored files git would delete along with the worktree that look
        /// like secrets or local config nobody can regenerate.
        var ignoredEnvFiles: [String] {
            ignored.filter { path in
                let name = (path.hasSuffix("/") ? String(path.dropLast()) : path)
                    .split(separator: "/").last.map(String.init) ?? path
                return name.hasPrefix(".env")
            }
        }

        /// Ignored entries that are not inside a build-artifact folder
        /// (`artifactDirectoryNames`). `git worktree remove` deletes them
        /// without asking, and nothing says they can be regenerated: a
        /// config/master.key, a secrets/ folder, a vendored clone.
        var ignoredOutsideBuildFolders: [String] {
            ignored.filter { !GitWorktreeSupport.isInsideArtifactFolder($0) }
        }
    }

    /// True when a `git status --ignored=matching` entry is a build-artifact
    /// folder or sits inside one ("apps/web/.next/", "node_modules/x.js").
    /// A file counts by the folders above it; its own name does not matter.
    static func isInsideArtifactFolder(_ entry: String) -> Bool {
        var parts = entry.split(separator: "/").map(String.init)
        if !entry.hasSuffix("/") { parts = Array(parts.dropLast()) }
        return parts.contains { artifactDirectoryNames.contains($0) }
    }

    /// Parse `git status --porcelain=v2 -z --untracked-files=all --ignored=matching`.
    static func parseStatus(_ output: String) -> WorkingTreeStatus {
        var status = WorkingTreeStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            switch field.first {
            case "1", "u":
                status.trackedChanges += 1
            case "2":
                // Renames/copies carry the original path as an extra field.
                status.trackedChanges += 1
                _ = fields.next()
            case "?":
                status.untracked.append(String(field.dropFirst(2)))
            case "!":
                status.ignored.append(String(field.dropFirst(2)))
            default:
                break
            }
        }
        return status
    }

    // MARK: - Stash attribution

    /// True when a stash entry belongs to this worktree: its subject names
    /// the worktree's branch ("WIP on <branch>: …" / "On <branch>: …"), or,
    /// for a detached worktree, the stash was made on top of its HEAD. A
    /// HEAD match is not used for branches: fresh worktrees often share the
    /// same base commit and would all claim one stash. Stashes are shared by
    /// the whole repository, so unattributed ones are ignored.
    /// `output` is `git stash list --format=%P%x00%gs%x00`.
    static func hasAttributedStash(_ output: String, branch: String?, head: String?) -> Bool {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index + 1 < fields.count {
            let parents = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = fields[index + 1]
            index += 2
            if let branch {
                if subject.hasPrefix("WIP on \(branch):") || subject.hasPrefix("On \(branch):") { return true }
            } else if let head, parents.split(separator: " ").first.map(String.init) == head {
                return true
            }
        }
        return false
    }

    // MARK: - Reflog

    /// True when the worktree's own HEAD reflog shows work done in it
    /// (commits, merges, rebases, cherry-picks) rather than just being
    /// created from the base branch.
    static func reflogShowsOwnWork(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            ["commit", "merge", "rebase", "cherry-pick", "revert"].contains { line.hasPrefix($0) }
        }
    }

    /// `git cherry <base> HEAD` prints "- sha" for commits already applied
    /// upstream and "+ sha" for the rest. Empty output means nothing to apply.
    static func cherryAllApplied(_ output: String) -> Bool {
        !output.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("+") }
    }

    // MARK: - Classification

    struct Signals: Equatable {
        var listed: ListedWorktree
        var status = WorkingTreeStatus()
        var hasAttributedStash = false
        /// Commits reachable from HEAD and from no remote or other branch.
        var uniqueCommits = 0
        /// The base ref ("origin/main") or nil when none could be resolved.
        var baseRef: String?
        var isAncestorOfBase = false
        var cherryAllApplied = false
        var hadOwnWork = false
        var lastActivity: Date?
        var inUse = false
        var isAgentWorktree = false
        /// A `.git` file or folder was found inside an ignored folder: a
        /// separate repository whose commits live only there.
        var nestedRepositoryInIgnored = false
        /// `.env*` entries found inside ignored folders (outside build folders).
        var envFilesInIgnoredFolders = 0
        /// The walk of the ignored folders hit its limit or an unreadable folder.
        var ignoredFoldersNotFullyChecked = false
    }

    enum Status: String, Equatable {
        case safeToDelete
        case needsReview
        case protected
        case orphan

        /// Protected and orphan rows are not removable as worktrees.
        /// `Verdict.blocksSelection` is the effective rule: it lets prunable
        /// orphans through for `git worktree prune`.
        var blocksSelection: Bool { self == .protected || self == .orphan }

        /// Order used to compare a fresh verdict with the scanned one.
        var severity: Int {
            switch self {
            case .safeToDelete: return 0
            case .needsReview: return 1
            case .protected: return 2
            case .orphan: return 3
            }
        }
    }

    enum Reason: Equatable {
        case trackedChanges(Int)
        case uniqueCommits(Int)
        case stash
        case locked
        case inUse
        case recentAgentActivity
        case prunable
        case notListedByGit
        case untrackedFiles(Int)
        case envFiles
        case ignoredOutsideBuildFolders(Int)
        case nestedRepositoryInIgnored
        case ignoredFoldersNotFullyChecked
        case noBaseBranch
        case notMerged
        case noOwnCommits
        case activeRecently(days: Int)
        case mergedAndIdle(days: Int)

        /// The case without its payload.
        var kind: String {
            switch self {
            case .trackedChanges: return "trackedChanges"
            case .uniqueCommits: return "uniqueCommits"
            case .stash: return "stash"
            case .locked: return "locked"
            case .inUse: return "inUse"
            case .recentAgentActivity: return "recentAgentActivity"
            case .prunable: return "prunable"
            case .notListedByGit: return "notListedByGit"
            case .untrackedFiles: return "untrackedFiles"
            case .envFiles: return "envFiles"
            case .ignoredOutsideBuildFolders: return "ignoredOutsideBuildFolders"
            case .nestedRepositoryInIgnored: return "nestedRepositoryInIgnored"
            case .ignoredFoldersNotFullyChecked: return "ignoredFoldersNotFullyChecked"
            case .noBaseBranch: return "noBaseBranch"
            case .notMerged: return "notMerged"
            case .noOwnCommits: return "noOwnCommits"
            case .activeRecently: return "activeRecently"
            case .mergedAndIdle: return "mergedAndIdle"
            }
        }
    }

    struct Verdict: Equatable {
        let status: Status
        let reasons: [Reason]

        /// A worktree whose folder is already gone and that git still lists.
        /// The only orphan with an action: `git worktree prune`.
        var isPrunableOrphan: Bool { status == .orphan && reasons == [.prunable] }

        /// What the UI and the clean step enforce: protected rows and orphans
        /// git does not know about can never be selected. Prunable orphans can.
        var blocksSelection: Bool { status.blocksSelection && !isPrunableOrphan }

        /// Reasons here that `scanned` did not have, compared by kind (a
        /// changed count or day number alone is not a new reason). The
        /// all-clear "merged, idle" reason never counts as a problem.
        func reasonsAdded(since scanned: Verdict) -> [Reason] {
            let before = Set(scanned.reasons.map(\.kind))
            return reasons.filter { !before.contains($0.kind) && $0.kind != "mergedAndIdle" }
        }

        /// True when the worktree looks worse now than when it was scanned:
        /// a more severe status, or a reason the scan did not report.
        func isWorse(than scanned: Verdict) -> Bool {
            status.severity > scanned.status.severity || !reasonsAdded(since: scanned).isEmpty
        }
    }

    static func classify(
        _ signals: Signals,
        now: Date = Date(),
        inactiveDays: Int = defaultInactiveDays
    ) -> Verdict {
        if signals.listed.isPrunable {
            return Verdict(status: .orphan, reasons: [.prunable])
        }

        let idleSeconds = signals.lastActivity.map { now.timeIntervalSince($0) } ?? .infinity
        let idleDays = idleSeconds.isFinite ? max(0, Int(idleSeconds / 86_400)) : Int.max

        var protectedReasons: [Reason] = []
        if signals.status.trackedChanges > 0 { protectedReasons.append(.trackedChanges(signals.status.trackedChanges)) }
        if signals.uniqueCommits > 0 { protectedReasons.append(.uniqueCommits(signals.uniqueCommits)) }
        if signals.hasAttributedStash { protectedReasons.append(.stash) }
        if signals.nestedRepositoryInIgnored { protectedReasons.append(.nestedRepositoryInIgnored) }
        if signals.listed.isLocked { protectedReasons.append(.locked) }
        if signals.inUse { protectedReasons.append(.inUse) }
        if signals.isAgentWorktree, idleSeconds < recentAgentActivityWindow {
            protectedReasons.append(.recentAgentActivity)
        }
        if !protectedReasons.isEmpty {
            return Verdict(status: .protected, reasons: protectedReasons)
        }

        var reviewReasons: [Reason] = []
        if !signals.status.untracked.isEmpty { reviewReasons.append(.untrackedFiles(signals.status.untracked.count)) }
        if !signals.status.ignoredEnvFiles.isEmpty || signals.envFilesInIgnoredFolders > 0 { reviewReasons.append(.envFiles) }
        let ignoredOutside = signals.status.ignoredOutsideBuildFolders.count
        if ignoredOutside > 0 { reviewReasons.append(.ignoredOutsideBuildFolders(ignoredOutside)) }
        if signals.ignoredFoldersNotFullyChecked { reviewReasons.append(.ignoredFoldersNotFullyChecked) }
        let merged = signals.isAncestorOfBase || signals.cherryAllApplied
        if signals.baseRef == nil {
            reviewReasons.append(.noBaseBranch)
        } else if !merged {
            reviewReasons.append(.notMerged)
        } else if signals.isAncestorOfBase && !signals.hadOwnWork {
            // HEAD == base (or behind it) with nothing done here: a fresh
            // worktree looks exactly like a merged one.
            reviewReasons.append(.noOwnCommits)
        }
        if idleSeconds < TimeInterval(inactiveDays) * 86_400 {
            reviewReasons.append(.activeRecently(days: idleDays))
        }
        if !reviewReasons.isEmpty {
            return Verdict(status: .needsReview, reasons: reviewReasons)
        }

        return Verdict(status: .safeToDelete, reasons: [.mergedAndIdle(days: idleDays)])
    }

    // MARK: - Paths

    /// Folders where AI coding agents create one worktree per task.
    static func globalAgentWorktreeRoots(homeDirectory: String) -> [String] {
        ["\(homeDirectory)/.cursor/worktrees", "\(homeDirectory)/.codex/worktrees"]
    }

    static func isAgentWorktreePath(_ path: String, homeDirectory: String) -> Bool {
        if path.contains("/.claude/worktrees/") { return true }
        return globalAgentWorktreeRoots(homeDirectory: homeDirectory).contains { root in
            path.hasPrefix(root + "/")
        }
    }

    /// Paths Claude Code has opened, from the keys of `projects` in
    /// ~/.claude.json. Nothing else in that file is read.
    static func claudeProjectPaths(fromClaudeJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any]
        else { return [] }
        return projects.keys.sorted()
    }

    /// Main repository for a `git rev-parse --git-common-dir` answer, or nil
    /// for bare repositories (whose common dir is not a `.git` folder).
    static func mainRepository(forCommonDir commonDir: String) -> String? {
        let url = URL(fileURLWithPath: commonDir.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
        guard url.lastPathComponent == ".git" else { return nil }
        return url.deletingLastPathComponent().path
    }

    /// Relative paths of the ignored folders in a `git status --ignored=matching`
    /// listing whose name is a build-artifact name ("apps/web/.next/" becomes
    /// "apps/web/.next"). Only folders git itself reports as ignored count.
    static func artifactDirectories(inIgnored ignored: [String]) -> [String] {
        ignored.compactMap { entry in
            guard entry.hasSuffix("/") else { return nil }
            let relative = String(entry.dropLast())
            guard let name = relative.split(separator: "/").last, artifactDirectoryNames.contains(String(name)) else { return nil }
            return relative
        }
    }

    /// True for a name that is safe to hand to git as a revision: no leading
    /// dash (option injection), no whitespace, control or revision-syntax
    /// characters. Used for the base-branch setting.
    static func isValidRevisionName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix(".lock"),
              !name.contains(".."), !name.contains("@{")
        else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "~^:?*[\\"))
        return name.rangeOfCharacter(from: forbidden) == nil
    }

    /// The full refs a base-branch setting may mean, or nil when it can only
    /// mean something else. Only `refs/heads/*` and `refs/remotes/*` qualify:
    /// `HEAD`, `@` and the other pseudo-refs name whatever is checked out
    /// where git runs, and a SHA names a commit, not a branch. A short name
    /// is tried as a local branch and as a remote-tracking branch; the caller
    /// uses the one that exists (and refuses when both do).
    static func baseRefCandidates(for setting: String) -> [String]? {
        let name = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRevisionName(name), name != "@", name != "HEAD" else { return nil }
        if name.range(of: "^[A-Z][A-Z_]*$", options: .regularExpression) != nil { return nil }
        if name.range(of: "^[0-9a-fA-F]{4,64}$", options: .regularExpression) != nil { return nil }
        if name.hasPrefix("refs/") {
            guard name.hasPrefix("refs/heads/") || name.hasPrefix("refs/remotes/") else { return nil }
            return [name]
        }
        return ["refs/heads/\(name)", "refs/remotes/\(name)"]
    }

    /// Why a base-branch setting can never work, for the Settings screen;
    /// nil when it is empty (automatic) or could name a branch.
    static func baseBranchSettingProblem(_ setting: String) -> String? {
        let name = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, baseRefCandidates(for: name) == nil else { return nil }
        return String(localized: "Use a branch name such as main or origin/main. HEAD, tags and commit hashes are not accepted.")
    }

    /// True when `path` equals `root` or sits inside it.
    static func isInside(_ path: String, root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }
}

// MARK: - Presentation

extension GitWorktreeSupport.Status {
    var label: String {
        switch self {
        case .safeToDelete: return String(localized: "Safe to delete")
        case .needsReview: return String(localized: "Needs review")
        case .protected: return String(localized: "Protected")
        case .orphan: return String(localized: "Orphan")
        }
    }
}

extension GitWorktreeSupport.Reason {
    var localizedDescription: String {
        switch self {
        case .trackedChanges(let count): return String(localized: "uncommitted changes (\(count))")
        case .uniqueCommits(let count): return String(localized: "commits not on any remote or other branch (\(count))")
        case .stash: return String(localized: "stashed changes")
        case .locked: return String(localized: "locked by git")
        case .inUse: return String(localized: "open in a running process")
        case .recentAgentActivity: return String(localized: "agent worktree active in the last 24 hours")
        case .prunable: return String(localized: "folder is gone; git still lists it")
        case .notListedByGit: return String(localized: "not a worktree its repository knows about")
        case .untrackedFiles(let count): return String(localized: "untracked files (\(count))")
        case .envFiles: return String(localized: "ignored .env files would be deleted")
        case .ignoredOutsideBuildFolders(let count): return String(localized: "ignored files outside build folders (\(count))")
        case .nestedRepositoryInIgnored: return String(localized: "nested repository in ignored folder")
        case .ignoredFoldersNotFullyChecked: return String(localized: "ignored folders too large to check completely")
        case .noBaseBranch: return String(localized: "no main branch to compare with")
        case .notMerged: return String(localized: "not merged into the main branch")
        case .noOwnCommits: return String(localized: "no commits of its own")
        case .activeRecently(let days): return String(localized: "active \(days) days ago")
        case .mergedAndIdle(let days): return days == Int.max
            ? String(localized: "merged, no recent activity")
            : String(localized: "merged, idle for \(days) days")
        }
    }
}

extension GitWorktreeReport {
    /// "artifacts 1.2 GB · code 40 MB"; nil for a worktree with no size.
    var sizeBreakdownText: String? {
        guard totalBytes > 0 else { return nil }
        let artifacts = ByteCountFormatter.string(fromByteCount: artifactBytes, countStyle: .file)
        let code = ByteCountFormatter.string(fromByteCount: codeBytes, countStyle: .file)
        return String(localized: "artifacts \(artifacts) · code \(code)")
    }
}

extension GitWorktreeSupport.Verdict {
    /// "Needs review · not merged into the main branch, untracked files (2)"
    var summary: String {
        ([status.label] + [reasons.map(\.localizedDescription).joined(separator: ", ")])
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
