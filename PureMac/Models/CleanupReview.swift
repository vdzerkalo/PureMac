import Foundation

enum CleanupSizeFilter: String, CaseIterable, Identifiable {
    case any = "Any size"
    case megabytes100 = "Over 100 MB"
    case gigabyte1 = "Over 1 GB"
    case gigabytes10 = "Over 10 GB"

    var id: String { rawValue }

    var minimumBytes: Int64 {
        switch self {
        case .any: return 0
        case .megabytes100: return 100_000_000
        case .gigabyte1: return 1_000_000_000
        case .gigabytes10: return 10_000_000_000
        }
    }
}

enum CleanupAgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Older than 30 days"
    case sixMonths = "Older than 6 months"
    case year = "Older than a year"

    var id: String { rawValue }

    func cutoff(relativeTo now: Date) -> Date? {
        switch self {
        case .any: return nil
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .sixMonths: return Calendar.current.date(byAdding: .month, value: -6, to: now)
        case .year: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        }
    }
}

enum CleanupSortOrder: String, CaseIterable, Identifiable {
    case largest = "Largest first"
    case smallest = "Smallest first"
    case oldest = "Oldest first"
    case name = "Name"

    var id: String { rawValue }
}

struct CleanupReviewFilter {
    var query = ""
    var size: CleanupSizeFilter = .any
    var age: CleanupAgeFilter = .any
    var order: CleanupSortOrder = .largest
    var worktreeStatus: GitWorktreeSupport.Status?
    var worktreeAction: WorktreeActionFilter = .any
    var worktreeRepository: WorktreeRepositoryFilter = .any

    func apply(to items: [CleanableItem], now: Date = Date()) -> [CleanableItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = age.cutoff(relativeTo: now)
        return items.filter { item in
            if let worktreeStatus, item.worktreeStatus != worktreeStatus { return false }
            guard worktreeAction.includes(item), worktreeRepository.includes(item) else { return false }
            guard item.size >= size.minimumBytes else { return false }
            if let cutoff {
                guard let modified = item.lastModified, modified < cutoff else { return false }
            }
            return search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                || item.path.localizedCaseInsensitiveContains(search)
        }.sorted { left, right in
            switch order {
            case .largest where left.size != right.size: return left.size > right.size
            case .smallest where left.size != right.size: return left.size < right.size
            case .oldest where left.lastModified != right.lastModified:
                return (left.lastModified ?? .distantFuture) < (right.lastModified ?? .distantFuture)
            default:
                let comparison = left.name.localizedStandardCompare(right.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.path < right.path
            }
        }
    }
}

enum WorktreeActionFilter: String, CaseIterable, Identifiable {
    case any = "All actions"
    case worktree = "Whole worktrees"
    case artifacts = "Build folders"

    var id: String { rawValue }

    func includes(_ item: CleanableItem) -> Bool {
        switch self {
        case .any: return true
        case .worktree: return item.gitWorktree != nil
        case .artifacts: return item.worktreeArtifacts != nil
        }
    }
}

enum WorktreeRepositoryFilter: Hashable {
    case any
    case unknown
    case path(String)

    func includes(_ item: CleanableItem) -> Bool {
        switch self {
        case .any: return true
        case .unknown: return item.worktreeRepositoryPath == nil
        case .path(let path): return item.worktreeRepositoryPath == path
        }
    }
}

extension CleanableItem {
    var worktreePath: String? { gitWorktree?.path ?? worktreeArtifacts?.worktreePath }
    var worktreeRepositoryPath: String? { gitWorktree?.repositoryPath ?? worktreeArtifacts?.repositoryPath }
    var worktreeStatus: GitWorktreeSupport.Status? { gitWorktree?.verdict.status ?? worktreeArtifacts?.worktreeVerdict.status }
}

struct WorktreeRepositoryGroup: Identifiable {
    let path: String?
    let items: [CleanableItem]

    var id: WorktreeRepositoryFilter { path.map(WorktreeRepositoryFilter.path) ?? .unknown }
    var name: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Unknown repository") }

    static func make(from sortedItems: [CleanableItem]) -> [Self] {
        Dictionary(grouping: sortedItems, by: \.worktreeRepositoryPath).map { path, rows in
            let parents = Set(rows.compactMap { $0.gitWorktree?.path })
            let children = Dictionary(grouping: rows.filter { $0.worktreeArtifacts != nil }, by: \.worktreePath)
            let adjacent = rows.flatMap { row -> [CleanableItem] in
                if let parent = row.gitWorktree {
                    return [row] + (children[parent.path] ?? [])
                }
                if let path = row.worktreePath, parents.contains(path) { return [] }
                return [row]
            }
            return Self(path: path, items: adjacent)
        }.sorted {
            if $0.path == nil { return false }
            if $1.path == nil { return true }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return ($0.path ?? "") < ($1.path ?? "")
        }
    }
}

struct CategoryCleanupProgress {
    let category: CleaningCategory
    let total: Int
    var completed = 0
    var currentItem: String?
    var finalizing = false
}

struct CategoryCleanupReport {
    struct Entry: Identifiable {
        enum Outcome: String {
            case completed = "Completed"
            case skipped = "Skipped"
            case unfinished = "Unfinished"
        }

        let id: UUID
        let name: String
        let outcome: Outcome
    }

    let finishedAt = Date()
    let entries: [Entry]
    let completed: Int
    let skipped: Int
    let unfinished: Int
    let estimatedBytes: Int64
    let reportedBytes: Int64
    let freeSpaceChange: Int64?
    let messages: [String]

    init(items: [CleanableItem], result: CleaningEngine.CleaningResult, before: DiskInfo, after: DiskInfo) {
        let skippedPaths = result.protectedPaths.union(result.skippedPaths)
        var seen: Set<String> = []
        entries = items.compactMap { item in
            guard seen.insert(item.path).inserted else { return nil }
            let outcome: Entry.Outcome
            if result.cleanedPaths.contains(item.path) {
                outcome = .completed
            } else if skippedPaths.contains(item.path) {
                outcome = .skipped
            } else {
                outcome = .unfinished
            }
            return Entry(id: item.id, name: item.name, outcome: outcome)
        }
        completed = entries.filter { $0.outcome == .completed }.count
        skipped = entries.filter { $0.outcome == .skipped }.count
        unfinished = entries.count - completed - skipped
        estimatedBytes = items.reduce(0) { $0 + $1.size }
        reportedBytes = result.freedSpace
        freeSpaceChange = before.totalSpace > 0 && after.totalSpace > 0 ? after.freeSpace - before.freeSpace : nil
        messages = result.errors + result.notes
    }
}
