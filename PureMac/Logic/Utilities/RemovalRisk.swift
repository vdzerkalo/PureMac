import Foundation

/// Extra friction for removals that touch the user's own developer data
/// (Docker objects): the review sheet lists the concrete risks and every
/// one must be acknowledged before a final confirmation. Also builds a
/// compact prompt the user can hand to an AI agent to get a second opinion
/// before anything is deleted.
enum RemovalRisk {
    static func requiresAcknowledgement(_ category: CleaningCategory) -> Bool {
        category == .dockerCache
    }

    /// The risks the user confirms one by one for the items under review.
    static func risks(for category: CleaningCategory, items: [CleanableItem]) -> [String] {
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
                risks.append(String(localized: "Unused volumes are erased with their data (databases, uploads); no pull or build brings it back."))
            }
            return risks
        default:
            return []
        }
    }

    /// How an item is removed, as a command an agent can reason about.
    static func action(for item: CleanableItem) -> String {
        if let prune = item.dockerPruneAction { return prune.commandLine }
        if item.isActionItem { return item.name }
        return "delete \((item.path as NSString).abbreviatingWithTildeInPath)"
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
        var lines = [
            "PureMac cleanup review — \(category.rawValue), \(day). Read-only: do not delete, change or run cleanup commands. No sub-agents.",
            "✔ = proposed for removal, · = found only.",
            "",
            "| # | | item | size | action | PureMac says |",
            "|---|---|---|---|---|---|",
        ]
        for (index, item) in found.enumerated() {
            let mark = proposed.contains(item.id) ? "✔" : "·"
            let cells = [
                "\(index + 1)", mark, item.name,
                ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                "`\(action(for: item))`", note(for: item),
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
        if item.requiresExplicitSelection { return "opt-in only; erases data" }
        return item.isSelected ? "selected by default" : "opt-in"
    }

    private static func readOnlyChecks(for category: CleaningCategory) -> String {
        switch category {
        case .dockerCache: return "docker ps -a, docker images --filter dangling=true, docker volume ls, docker system df -v"
        default: return "list and inspect only"
        }
    }
}
