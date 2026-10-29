import Darwin
import Foundation

/// One ignored build folder inside a worktree, relative to the worktree.
struct WorktreeArtifactFolder: Equatable {
    let relativePath: String
    var bytes: Int64 = 0
}

/// The "Artifacts in <repo · branch>" row: build folders (node_modules,
/// .next, …) that git ignores inside a worktree that cannot be removed as a
/// whole (Needs review or Protected). Carried on its CleanableItem so the
/// clean step knows which folders to re-check and delete.
struct WorktreeArtifactsReport: Equatable {
    let worktreePath: String
    let repositoryPath: String
    let branch: String?
    let head: String?
    /// The worktree's own verdict at scan time.
    let worktreeVerdict: GitWorktreeSupport.Verdict
    var folders: [WorktreeArtifactFolder]

    var totalBytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }

    /// Why this row cannot be selected, if it cannot.
    var blocker: GitWorktreeSupport.Reason? { WorktreeArtifactSupport.blocker(for: worktreeVerdict) }

    var displayName: String {
        let repo = URL(fileURLWithPath: repositoryPath).lastPathComponent
        let ref = branch ?? head.map { String($0.prefix(8)) } ?? URL(fileURLWithPath: worktreePath).lastPathComponent
        return "\(repo) · \(ref)"
    }
}

/// Filesystem rules for cleaning build artifacts inside a worktree. Pure of
/// git: GitWorktreeScanner adds the `check-ignore` / `ls-files` checks.
enum WorktreeArtifactSupport {
    /// Path of a row's CleanableItem; not a real path, so the generic
    /// delete route can never act on it.
    static let rowPathPrefix = "worktree-artifacts:"
    /// Artifact folders are looked for at most this many levels below the
    /// worktree root ("a/b/c/node_modules" is level 4).
    static let maxDepth = 4
    static let entryLimit = 100_000

    static func rowPath(forWorktree path: String) -> String { rowPathPrefix + path }

    /// A worktree in use, active as an agent worktree in the last 24 hours,
    /// or locked by git keeps its artifacts: a dev server or build running
    /// there would break.
    static func blocker(for verdict: GitWorktreeSupport.Verdict) -> GitWorktreeSupport.Reason? {
        verdict.reasons.first { reason in
            switch reason {
            case .inUse, .recentAgentActivity, .locked: return true
            default: return false
            }
        }
    }

    /// Folders named in `GitWorktreeSupport.artifactDirectoryNames`, found by
    /// a bounded walk: at most `maxDepth` levels, `.git` skipped, symlinks
    /// never followed, a found artifact folder not entered, and nested
    /// repositories and worktrees (a folder with its own `.git`) not entered.
    /// Relative paths, sorted. Git has not been asked yet.
    static func candidates(in worktree: String) -> [String] {
        var found: [String] = []
        var visited = 0
        func walk(_ directory: String, relative: [String]) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for entry in entries.sorted() where entry != ".git" {
                visited += 1
                if visited > entryLimit || Task.isCancelled { return }
                let child = (directory as NSString).appendingPathComponent(entry)
                var info = stat()
                guard lstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                let path = relative + [entry]
                if GitWorktreeSupport.artifactDirectoryNames.contains(entry) {
                    found.append(path.joined(separator: "/"))
                } else if path.count < maxDepth, !GitWorktreeScanner.pathExists((child as NSString).appendingPathComponent(".git")) {
                    walk(child, relative: path)
                }
            }
        }
        walk(worktree, relative: [])
        return found.sorted()
    }

    enum Check: Equatable {
        /// The folder passed; `resolved` is its real absolute path.
        case ok(resolved: String)
        /// Nothing at that path any more.
        case missing
        case refused(String)
    }

    /// Filesystem checks, run again right before a folder is deleted:
    /// a plain relative path ending in an artifact name; a real directory,
    /// not a symlink; its realpath is exactly worktree-realpath + path (no
    /// symlink on the way, nothing escaping the worktree); same volume as the
    /// worktree; no `.git` in it or in a folder above it (nested repository).
    static func check(worktree: String, relative: String) -> Check {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.hasPrefix("/"), (1...maxDepth).contains(components.count),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" || $0.contains("\0") }),
              let name = components.last, GitWorktreeSupport.artifactDirectoryNames.contains(name)
        else { return .refused("not a build folder path") }

        let root = GitWorktreeScanner.canonical(worktree)
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return .refused("the worktree folder is gone") }
        let full = root + "/" + relative
        var info = stat()
        guard lstat(full, &info) == 0 else { return .missing }
        if (info.st_mode & S_IFMT) == S_IFLNK { return .refused("is a symlink") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .refused("is not a folder") }

        let real = GitWorktreeScanner.canonical(full)
        guard real == full, GitWorktreeSupport.isInside(real, root: root) else { return .refused("resolves outside the worktree") }
        guard info.st_dev == rootInfo.st_dev else { return .refused("is on another volume") }
        if GitWorktreeScanner.pathExists(full + "/.git") { return .refused("contains a repository") }
        var ancestor = root
        for component in components.dropLast() {
            ancestor += "/" + component
            if GitWorktreeScanner.pathExists(ancestor + "/.git") { return .refused("is inside a nested repository") }
        }
        return .ok(resolved: real)
    }
}
