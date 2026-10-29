import Foundation

/// Extra friction for removals that touch the user's own developer data
/// (Docker objects, git worktrees): the review sheet lists the concrete
/// risks and every one must be acknowledged before a final confirmation.
/// Also builds a compact prompt the user can hand to an AI agent to get a
/// second opinion before anything is deleted.
enum RemovalRisk {
    static func requiresAcknowledgement(_ category: CleaningCategory) -> Bool {
        category == .dockerCache || category == .gitWorktrees
    }

    /// The three risks the user confirms one by one.
    static func risks(for category: CleaningCategory) -> [String] {
        switch category {
        case .dockerCache:
            return [
                String(localized: "Nothing goes to the Trash: Docker deletes these objects permanently."),
                String(localized: "Removed images and build cache are downloaded or rebuilt on next use, so the next pull or build is slower."),
                String(localized: "Stopped containers and the files inside them are deleted; running containers are kept."),
            ]
        case .gitWorktrees:
            return [
                String(localized: "Each folder is removed with git worktree remove: everything inside it, including ignored files such as node_modules and .env, is deleted, not moved to the Trash."),
                String(localized: "Branches are kept. Commits are safe only if they are merged, pushed or on another branch; PureMac re-checks this right before removing."),
                String(localized: "Close any agent, editor or terminal still using these folders: they lose their working directory."),
            ]
        default:
            return []
        }
    }

    /// How an item is removed, as an agent can reason about it. Worktree
    /// paths are written relative to their repository (see `repositories`)
    /// so long absolute paths are not repeated on every row.
    static func action(for item: CleanableItem, repositories: [String: String] = [:]) -> String {
        if let worktree = item.gitWorktree {
            guard let repository = worktree.repositoryPath else { return "none (display only): \(abbreviate(item.path))" }
            let name = repositories[repository] ?? repository
            let relative = GitWorktreeSupport.isInside(item.path, root: repository)
                ? String(item.path.dropFirst(repository.count + 1))
                : abbreviate(item.path)
            return "worktree remove \(name):\(relative)"
        }
        if item.category == .dockerCache && item.path.isEmpty {
            return "docker system prune -f"
        }
        if item.isActionItem { return item.name }
        return "delete \(abbreviate(item.path))"
    }

    /// Short names for the repositories of the found worktrees: the folder
    /// name, or the full path when two repositories share one.
    static func repositoryNames(_ items: [CleanableItem]) -> [String: String] {
        let paths = Set(items.compactMap { $0.gitWorktree?.repositoryPath })
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
        date: Date = Date()
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
            lines.append("`worktree remove R:P` = `git -C R worktree remove P` (no --force, branch kept).")
        }
        lines += [
            "✔ = proposed for removal, · = found only.",
            "",
            "| # | | item | size | action | PureMac says |",
            "|---|---|---|---|---|---|",
        ]
        for (index, item) in found.enumerated() {
            let mark = proposed.contains(item.id) ? "✔" : "·"
            let verdict = item.gitWorktree?.verdict.englishSummary ?? (item.isSelected ? "selected by default" : "opt-in")
            let cells = [
                "\(index + 1)", mark, item.gitWorktree?.branch ?? item.name,
                ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                "`\(action(for: item, repositories: repositories))`", verdict,
            ].map { $0.replacingOccurrences(of: "|", with: "\\|") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines += [
            "",
            "Proposed: \(proposedItems.count) of \(found.count) items, \(ByteCountFormatter.string(fromByteCount: proposedBytes, countStyle: .file)).",
            "Do:",
            "1. Check each ✔ row read-only (git status/log/stash, docker ps/inspect). Note real risks only.",
            "2. Reply with one table: # | keep/remove | risk (≤6 words). No other text.",
            "3. Then ask the owner at most 3 yes/no questions, only where unsure.",
        ]
        return lines.joined(separator: "\n")
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
