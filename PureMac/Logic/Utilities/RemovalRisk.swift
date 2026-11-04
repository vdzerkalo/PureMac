import Foundation

/// Extra friction for removals that touch the user's own developer data
/// (Docker objects, git worktrees, local AI models): the review sheet lists
/// the concrete risks and every one must be acknowledged before a final
/// confirmation.
/// Also builds a compact prompt the user can hand to an AI agent to get a
/// second opinion before anything is deleted.
enum RemovalRisk {
    /// Set (c): the categories whose removal needs the risk sheet. Docker
    /// objects, worktrees and model downloads are permanent and are the
    /// user's own work or downloads; AI Agent Data goes to the Trash, so it
    /// has no sheet. Every category here is also in
    /// `CleaningCategory.overviewExcluded` (set (b)).
    static var acknowledgedCategories: Set<CleaningCategory> {
        [.dockerCache, .gitWorktrees, .localAIModels]
    }

    static func requiresAcknowledgement(_ category: CleaningCategory) -> Bool {
        acknowledgedCategories.contains(category)
    }

    /// The risks the user confirms one by one for the items under review.
    static func risks(
        for category: CleaningCategory,
        items: [CleanableItem],
        worktreeSettings: GitWorktreeSettings = .current()
    ) -> [String] {
        switch category {
        case .dockerCache:
            // One risk per kind of object the selected rows remove, worded for
            // the exact command; the volumes risk appears only with that row.
            let actions = Set(items.compactMap(\.dockerPruneAction))
            var risks = [
                String(localized: "Nothing goes to the Trash: Docker deletes these objects permanently."),
            ]
            if actions.contains(.buildCache) {
                risks.append(String(localized: "Build cache is deleted; the next build recreates it and is slower."))
            }
            if actions.contains(.stoppedContainers) {
                risks.append(String(localized: "Stopped containers and the files inside them are deleted; running containers are kept."))
            }
            if actions.contains(.unusedImages) {
                // Covers the dangling row too: `image prune -a` removes both.
                risks.append(String(localized: "All images no container uses are deleted, tagged or not; ones you built locally and never pushed can only be rebuilt, not downloaded."))
            } else if actions.contains(.danglingImages) {
                risks.append(String(localized: "Dangling images (no tag) are deleted; if you still need one, you have to rebuild it from its source."))
            }
            if actions.contains(.unusedVolumes) {
                risks.append(String(localized: "The volumes named in the command are erased with their data (databases, uploads); no pull or build brings it back."))
            }
            return risks
        case .gitWorktrees:
            let pruneOnly = items.filter { $0.gitWorktree?.verdict.isPrunableOrphan == true }
            let artifactRows = items.filter { $0.worktreeArtifacts != nil }
            var risks: [String] = []
            if items.isEmpty || pruneOnly.count + artifactRows.count < items.count {
                risks.append(String(localized: "Each folder is removed with git worktree remove: everything inside it, including ignored files such as node_modules and .env, is deleted, not moved to the Trash."))
                risks.append(worktreeSettings.deleteMergedBranch
                    ? String(localized: "Branches of Safe to delete worktrees are deleted with git branch -d, only if git agrees they are merged. Commits are safe only if they are merged, pushed or on another branch; PureMac re-checks this right before removing.")
                    : String(localized: "Branches are kept. Commits are safe only if they are merged, pushed or on another branch; PureMac re-checks this right before removing."))
                risks.append(String(localized: "Close any agent, editor or terminal still using these folders: they lose their working directory."))
            }
            if !pruneOnly.isEmpty {
                risks.append(String(localized: "git worktree prune deletes only git's records of worktrees whose folder is already gone; no files are touched. It applies to every missing worktree of that repository, selected or not."))
            }
            if !artifactRows.isEmpty {
                risks.append(String(localized: "Build folders such as node_modules, .next, dist or target inside these worktrees are deleted permanently, not moved to the Trash. Git ignores them and no tracked file is inside; the worktrees and their files stay, and your next install or build recreates the folders."))
                risks.append(String(localized: "Stop dev servers, watchers and builds running from these worktrees first. PureMac skips worktrees it sees in use, but cannot see every tool."))
            }
            return risks
        case .localAIModels:
            let ollama = items.contains { $0.ollamaModelName != nil }
            let files = items.contains { $0.ollamaModelName == nil }
            var risks = [
                String(localized: "Nothing goes to the Trash: models are deleted permanently."),
            ]
            if ollama {
                risks.append(String(localized: "Ollama models are removed through Ollama. Files shared with other models stay on disk, so less space may be freed than listed. Using a removed model again means pulling it again."))
            }
            if files {
                risks.append(String(localized: "Hugging Face repos and model folders are deleted with all their files. Using one again means downloading it in full, often many gigabytes, which can take hours on a slow connection."))
                risks.append(String(localized: "Files linked from outside the cache are not detected: a project that links into a deleted folder stops working."))
            }
            return risks
        default:
            return []
        }
    }

    /// How an item is removed, as an agent can reason about it. Worktree
    /// paths are written relative to their repository (see `repositories`)
    /// so long absolute paths are not repeated on every row.
    static func action(for item: CleanableItem, repositories: [String: String] = [:]) -> String {
        if let artifacts = item.worktreeArtifacts {
            let name = repositories[artifacts.repositoryPath] ?? artifacts.repositoryPath
            let relative = GitWorktreeSupport.isInside(artifacts.worktreePath, root: artifacts.repositoryPath)
                ? String(artifacts.worktreePath.dropFirst(artifacts.repositoryPath.count + 1))
                : abbreviate(artifacts.worktreePath)
            return "delete ignored folders \(name):\(relative)/{" + artifacts.folders.map(\.relativePath).joined(separator: ",") + "}"
        }
        if let worktree = item.gitWorktree {
            guard let repository = worktree.repositoryPath else { return "none (display only): \(abbreviate(item.path))" }
            let name = repositories[repository] ?? repository
            if worktree.verdict.isPrunableOrphan { return "worktree prune \(name)" }
            let relative = GitWorktreeSupport.isInside(item.path, root: repository)
                ? String(item.path.dropFirst(repository.count + 1))
                : abbreviate(item.path)
            return "worktree remove \(name):\(relative)"
        }
        if let command = item.dockerCommandLine { return command }
        if let model = item.ollamaModelName { return "ollama rm \(model)" }
        if item.isActionItem { return item.name }
        return "delete \(abbreviate(item.path))"
    }

    /// Short names for the repositories of the found worktrees: the folder
    /// name, or the full path when two repositories share one.
    static func repositoryNames(_ items: [CleanableItem]) -> [String: String] {
        let paths = Set(items.compactMap { $0.gitWorktree?.repositoryPath ?? $0.worktreeArtifacts?.repositoryPath })
        let counts = Dictionary(grouping: paths) { URL(fileURLWithPath: $0).lastPathComponent }.mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: paths.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (path, counts[name] == 1 ? name : abbreviate(path))
        })
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// A short, table-first brief for an AI agent: every item found in the
    /// category, the ones proposed for removal marked ✔, and instructions to
    /// verify read-only, answer in one table and ask the owner only what is
    /// unclear. English and terse on purpose — it is pasted into a prompt.
    static func agentPrompt(
        category: CleaningCategory,
        found: [CleanableItem],
        proposed: Set<UUID>,
        date: Date = Date(),
        worktreeSettings: GitWorktreeSettings = .current()
    ) -> String {
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        let proposedItems = found.filter { proposed.contains($0.id) }
        let proposedBytes = proposedItems.reduce(Int64(0)) { $0 + $1.size }
        let repositories = repositoryNames(found)
        var lines = [
            "PureMac cleanup review — \(category.rawValue), \(day). Read-only: do not delete, change or run cleanup commands. No sub-agents.",
        ]
        if !repositories.isEmpty {
            lines.append("Repos: " + repositories.sorted { $0.value < $1.value }
                .map { "\($0.value) = \(abbreviate($0.key))" }.joined(separator: "; "))
            lines.append("`worktree remove R:P` = `git -C R worktree remove P` (no --force, "
                + (worktreeSettings.deleteMergedBranch ? "then `git branch -d` for safe rows)." : "branch kept)."))
            if found.contains(where: { $0.gitWorktree?.verdict.isPrunableOrphan == true }) {
                lines.append("`worktree prune R` = `git -C R worktree prune` (folder already gone; git records only).")
            }
            if found.contains(where: { $0.worktreeArtifacts != nil }) {
                lines.append("`delete ignored folders R:P/{…}` = delete only those build folders inside worktree P (each git-ignored, none tracked, no symlinks); the worktree stays.")
            }
        }
        lines += [
            "✔ = proposed for removal, · = found only.",
            "",
            "| # | | item | size | action | PureMac says |",
            "|---|---|---|---|---|---|",
        ]
        for (index, item) in found.enumerated() {
            let mark = proposed.contains(item.id) ? "✔" : "·"
            let verdict = item.gitWorktree?.verdict.englishSummary ?? note(for: item)
            let cells = [
                "\(index + 1)", mark, item.gitWorktree?.branch ?? item.worktreeArtifacts.map { "artifacts: " + ($0.branch ?? $0.displayName) } ?? item.name,
                ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                "`\(action(for: item, repositories: repositories))`", verdict,
            ].map { $0.replacingOccurrences(of: "|", with: "\\|") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines += [
            "",
            "Proposed: \(proposedItems.count) of \(found.count) items, \(ByteCountFormatter.string(fromByteCount: proposedBytes, countStyle: .file)).",
            "Do:",
            "1. Check each ✔ row read-only (\(readOnlyChecks(for: category))). Note real risks only.",
            "2. Reply with one table: # | keep/remove | risk (≤6 words). No other text.",
            "3. Then ask the owner at most 3 yes/no questions, only where unsure.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func note(for item: CleanableItem) -> String {
        if let artifacts = item.worktreeArtifacts {
            let worktree = artifacts.worktreeVerdict.englishSummary
            if let nested = artifacts.nestedRepository {
                return "BLOCKED (a build folder contains a git repository: \(nested)); worktree is \(worktree)"
            }
            return artifacts.blocker == nil
                ? "opt-in; regenerable build folders only; worktree is \(worktree)"
                : "BLOCKED (worktree busy); worktree is \(worktree)"
        }
        if item.requiresExplicitSelection { return "opt-in only; erases data" }
        if item.category == .localAIModels { return "opt-in; model download, permanent, shared files stay" }
        return item.isSelected ? "selected by default" : "opt-in"
    }

    private static func readOnlyChecks(for category: CleaningCategory) -> String {
        switch category {
        case .dockerCache: return "docker ps -a, docker images --filter dangling=true, docker volume ls, docker system df -v"
        case .gitWorktrees: return "git status, git log, git stash list"
        case .localAIModels: return "ollama list, hf cache ls, ls -la on the listed folders"
        default: return "list and inspect only"
        }
    }
}

extension GitWorktreeSupport.Verdict {
    /// Untranslated summary for the agent prompt.
    var englishSummary: String {
        let reasonText = reasons.map { reason -> String in
            switch reason {
            case .trackedChanges(let n): return "uncommitted changes (\(n))"
            case .uniqueCommits(let n): return "commits on no remote/other branch (\(n))"
            case .stash: return "stash"
            case .locked: return "locked"
            case .inUse: return "open in a process"
            case .recentAgentActivity: return "agent active <24h"
            case .prunable: return "folder gone, still listed"
            case .notListedByGit: return "not known to its repo"
            case .untrackedFiles(let n): return "untracked files (\(n))"
            case .envFiles: return "ignored .env files"
            case .ignoredOutsideBuildFolders(let n): return "ignored files outside build folders (\(n))"
            case .nestedRepositoryInIgnored: return "nested repository in ignored folder"
            case .ignoredFoldersNotFullyChecked: return "ignored folders too large to check completely"
            case .noBaseBranch: return "no main branch"
            case .notMerged: return "not merged"
            case .noOwnCommits: return "no own commits"
            case .activeRecently(let d): return "active \(d)d ago"
            case .mergedAndIdle(let d): return d == Int.max ? "merged" : "merged, idle \(d)d"
            }
        }
        let statusText: String
        switch status {
        case .safeToDelete: statusText = "safe"
        case .needsReview: statusText = "review"
        case .protected: statusText = "PROTECTED"
        case .orphan: statusText = "orphan"
        }
        return ([statusText] + reasonText).joined(separator: "; ")
    }
}
