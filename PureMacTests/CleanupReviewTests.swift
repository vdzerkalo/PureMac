import XCTest
@testable import PureMac

final class CleanupReviewTests: XCTestCase {
    func testCombinedFiltersUseNameOrPathSizeAndAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-90 * 86_400)
        let items = [
            item("Archive", path: "/work/project/archive", size: 2_000_000_000, date: old),
            item("PROJECT", size: 1_500_000_000, date: now),
            item("project", size: 5, date: old),
            item("project", size: 3_000_000_000, date: nil)
        ]
        let filter = CleanupReviewFilter(query: " Project ", size: .gigabyte1, age: .month)
        XCTAssertEqual(filter.apply(to: items, now: now).map(\.id), [items[0].id])
    }

    func testSortUsesStableTiesAndUnknownDatesLast() {
        let a = item("Alpha", size: 100, date: Date(timeIntervalSince1970: 1))
        let b = item("Beta", size: 100, date: nil)
        let c = item("Charlie", size: 200, date: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(CleanupReviewFilter().apply(to: [b, c, a]).map(\.name), ["Charlie", "Alpha", "Beta"])
        XCTAssertEqual(CleanupReviewFilter(order: .oldest).apply(to: [b, c, a]).map(\.name), ["Alpha", "Charlie", "Beta"])
    }

    func testWorktreeGroupingUsesRepositoryPathsAndKeepsArtifactsWithTheirTree() {
        let first = worktree("/a/Project", name: "first", status: .needsReview)
        let second = worktree("/b/Project", name: "second", status: .protected)
        let third = worktree("/a/Project", name: "third", status: .protected)
        let groups = WorktreeRepositoryGroup.make(from: [first[1], second[1], third[0], first[0], third[1], second[0]])

        XCTAssertEqual(groups.map(\.path), ["/a/Project", "/b/Project"])
        XCTAssertEqual(groups[0].items.map(\.id), [third[0].id, third[1].id, first[0].id, first[1].id])
        XCTAssertEqual(groups[1].items.map(\.id), second.map(\.id))
    }

    func testWorktreeStatusAndActionFiltersCanShowArtifactsWithoutTheirParent() {
        let review = worktree("/a/Project", name: "review", status: .needsReview)
        let protected = worktree("/a/Project", name: "protected", status: .protected)
        let other = worktree("/b/Project", name: "other", status: .protected)
        let filter = CleanupReviewFilter(worktreeStatus: .protected, worktreeAction: .artifacts,
                                         worktreeRepository: .path("/a/Project"))
        let groups = WorktreeRepositoryGroup.make(from: filter.apply(to: review + protected + other))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.map(\.id), [protected[1].id])
        XCTAssertFalse(protected[1].isSelected, "The inherited status filter does not select artifact actions")
    }

    func testCleanupReportSeparatesSkippedAndUnfinishedFromMeasuredSpace() {
        let done = item("Done", path: "/done", size: 100, date: nil)
        let skipped = item("Busy", path: "/busy", size: 100, date: nil)
        let partial = item("Partial", path: "/partial", size: 100, date: nil)
        var result = CleaningEngine.CleaningResult()
        result.cleanedPaths = [done.path]
        result.skippedPaths = [skipped.path]
        result.freedSpace = 150
        result.errors = ["Busy", "Partial"]
        let report = CategoryCleanupReport(items: [done, skipped, partial], result: result,
                                            before: DiskInfo(totalSpace: 1000, freeSpace: 400),
                                            after: DiskInfo(totalSpace: 1000, freeSpace: 390))
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.unfinished, 1)
        XCTAssertEqual(report.entries.map(\.name), ["Done", "Busy", "Partial"])
        XCTAssertEqual(report.entries.map(\.outcome), [.completed, .skipped, .unfinished])
        XCTAssertEqual(report.estimatedBytes, 300)
        XCTAssertEqual(report.reportedBytes, 150)
        XCTAssertEqual(report.freeSpaceChange, -10, "Concurrent disk activity can outweigh cleanup")
        XCTAssertEqual(report.messages, ["Busy", "Partial"])
    }

    private func worktree(_ repo: String, name: String, status: GitWorktreeSupport.Status) -> [CleanableItem] {
        let path = "\(repo)/wt/\(name)"
        let verdict = GitWorktreeSupport.Verdict(status: status, reasons: [])
        let report = GitWorktreeReport(path: path, repositoryPath: repo, branch: name, head: nil,
                                       verdict: verdict, lastActivity: nil, artifactBytes: 50, codeBytes: 10)
        let artifacts = WorktreeArtifactsReport(worktreePath: path, repositoryPath: repo, branch: name,
                                                head: nil, worktreeVerdict: verdict,
                                                folders: [.init(relativePath: "node_modules", bytes: 50)])
        return report.cleanupItems(artifacts: artifacts, selectSafeWorktree: true)
    }

    private func item(_ name: String, path: String = "/fixture", size: Int64, date: Date?) -> CleanableItem {
        CleanableItem(name: name, path: path, size: size, category: .largeFiles, isSelected: false, lastModified: date)
    }
}
