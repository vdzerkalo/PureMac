import XCTest
@testable import PureMac

/// Pins the rules that span several developer-cleanup categories: the three
/// category sets, the single bulk-selection rule and the Docker deny list
/// that every deletion route consults. See docs/DEVELOPER-CLEANUP.md.
extension UserDefaults {
    /// Empty defaults for an AppState under test, so the Smart Scan opt-ins
    /// (`CleaningCategory.smartScanOptInKey`) the user set in the real app
    /// never change what a test sees. Nothing is written unless a test does.
    static var isolatedForTests: UserDefaults {
        UserDefaults(suiteName: "PureMac.Tests.\(UUID().uuidString)")!
    }
}

final class CategoryRulesTests: XCTestCase {
    /// Expected membership of every category. A new `CleaningCategory` case
    /// without a row here fails `testEveryCategoryHasAnExpectedMembership`.
    private struct Membership {
        /// (a) Smart Scan, scheduled scans and scheduled cleaning.
        let smartScan: Bool
        /// (b) Excluded from Overview totals, selection and every `cleanAll`.
        let overviewExcluded: Bool
        /// (c) Removal needs the risk-acknowledgement sheet.
        let riskSheet: Bool
    }

    private static let expected: [CleaningCategory: Membership] = [
        .smartScan: Membership(smartScan: false, overviewExcluded: false, riskSheet: false),
        .systemJunk: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .userCache: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .aiApps: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .aiAgentData: Membership(smartScan: false, overviewExcluded: true, riskSheet: false),
        .mailAttachments: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .trashBins: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .largeFiles: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .purgeableSpace: Membership(smartScan: false, overviewExcluded: false, riskSheet: false),
        .xcodeJunk: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .brewCache: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .nodeCache: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .devToolCaches: Membership(smartScan: true, overviewExcluded: false, riskSheet: false),
        .dockerCache: Membership(smartScan: true, overviewExcluded: true, riskSheet: true),
        .gitWorktrees: Membership(smartScan: false, overviewExcluded: true, riskSheet: true),
        .localAIModels: Membership(smartScan: false, overviewExcluded: true, riskSheet: true),
        .universalBinaries: Membership(smartScan: false, overviewExcluded: false, riskSheet: false),
        .languageFiles: Membership(smartScan: false, overviewExcluded: false, riskSheet: false),
    ]

    func testEveryCategoryHasAnExpectedMembership() {
        XCTAssertEqual(Set(Self.expected.keys), Set(CleaningCategory.allCases))
    }

    func testSetAIsSmartScanAndSchedules() {
        for category in CleaningCategory.allCases {
            let expectation = Self.expected[category]!
            XCTAssertEqual(CleaningCategory.smartScannable.contains(category), expectation.smartScan, category.rawValue)
            XCTAssertEqual(
                ScheduleConfig().categoriesToScan.contains(category), expectation.smartScan,
                "\(category.rawValue): a new schedule scans exactly the Smart Scan categories"
            )
        }
        for category: CleaningCategory in [.localAIModels, .aiAgentData, .gitWorktrees] {
            XCTAssertFalse(CleaningCategory.smartScannable.contains(category), category.rawValue)
            XCTAssertTrue(CleaningCategory.smartScanExcluded.contains(category), category.rawValue)
        }
    }

    func testSetBIsOverviewAndCleanAll() {
        for category in CleaningCategory.allCases {
            let expectation = Self.expected[category]!
            XCTAssertEqual(CleaningCategory.overviewExcluded.contains(category), expectation.overviewExcluded, category.rawValue)
        }
        for category: CleaningCategory in [.localAIModels, .aiAgentData, .gitWorktrees, .dockerCache] {
            XCTAssertTrue(CleaningCategory.overviewExcluded.contains(category), category.rawValue)
        }
    }

    func testSetCIsTheRiskSheet() {
        for category in CleaningCategory.allCases {
            let expectation = Self.expected[category]!
            XCTAssertEqual(RemovalRisk.requiresAcknowledgement(category), expectation.riskSheet, category.rawValue)
        }
    }

    func testSetsAreConsistentWithEachOther() {
        XCTAssertTrue(CleaningCategory.smartScanExcluded.isSubset(of: CleaningCategory.overviewExcluded),
                      "what Smart Scan skips, the Overview must not clean either")
        XCTAssertTrue(RemovalRisk.acknowledgedCategories.isSubset(of: CleaningCategory.overviewExcluded),
                      "a category that needs a risk review can only be removed from its own screen")
        XCTAssertTrue(Set(CleaningCategory.smartScannable).isSubset(of: Set(CleaningCategory.scannable)))
        XCTAssertEqual(
            Set(CleaningCategory.smartScannable),
            Set(CleaningCategory.scannable).subtracting(CleaningCategory.smartScanExcluded)
        )
    }

    func testEveryCategoryInTheSidebarListIsScannable() {
        // MainWindow filters its list with `scannable`; the three developer
        // review categories must be reachable there.
        for category: CleaningCategory in [.localAIModels, .aiAgentData, .gitWorktrees, .dockerCache, .devToolCaches] {
            XCTAssertTrue(CleaningCategory.scannable.contains(category), category.rawValue)
        }
    }

    @MainActor
    func testAppStateAgreesWithSetB() {
        let state = AppState(performStartupTasks: false, settingsDefaults: .isolatedForTests)
        for category in CleaningCategory.allCases {
            XCTAssertEqual(
                state.isReviewedInCategoryOnly(category), Self.expected[category]!.overviewExcluded, category.rawValue
            )
        }
    }

    func testLocalAIModelsRisksNameThePermanentRemovalSharedBlobsAndRedownload() {
        func row(_ name: String, path: String) -> CleanableItem {
            CleanableItem(name: name, path: path, size: 1, category: .localAIModels, isSelected: false,
                          lastModified: nil, selectOnlyByHand: true)
        }
        let ollama = row("qwen", path: CleanableItem.ollamaModelPathPrefix + "qwen:7b#0123456789abcdef")
        let hf = row("org/name", path: "/nonexistent/hub/models--org--name")

        let onlyOllama = RemovalRisk.risks(for: .localAIModels, items: [ollama])
        let onlyFiles = RemovalRisk.risks(for: .localAIModels, items: [hf])
        let both = RemovalRisk.risks(for: .localAIModels, items: [ollama, hf])

        XCTAssertEqual(onlyOllama.count, 2, "permanent + shared files")
        XCTAssertEqual(onlyFiles.count, 3, "permanent + download in full + links from outside")
        XCTAssertEqual(both.count, 4)
        XCTAssertTrue(both.contains { $0.contains("Trash") && $0.contains("permanently") })
        XCTAssertTrue(both.contains { $0.contains("shared") || $0.contains("Files shared") })
        XCTAssertTrue(both.contains { $0.contains("download") })
    }

    // MARK: - One bulk-selection rule

    /// Every kind of row that bulk selection must never select, plus controls
    /// that it must select.
    @MainActor
    private func makeRows() -> (state: AppState, skipped: [String: CleanableItem], controls: [String: CleanableItem]) {
        func plain(_ name: String, _ path: String, _ category: CleaningCategory, byHand: Bool = false) -> CleanableItem {
            CleanableItem(name: name, path: path, size: 4_096, category: category, isSelected: false,
                          lastModified: nil, selectOnlyByHand: byHand)
        }
        func worktree(_ name: String, _ verdict: GitWorktreeSupport.Verdict) -> CleanableItem {
            var item = plain(name, "/nonexistent/r/wt/\(name)", .gitWorktrees)
            item.gitWorktree = GitWorktreeReport(path: item.path, repositoryPath: "/nonexistent/r", branch: name,
                                                 head: nil, verdict: verdict, lastActivity: nil)
            return item
        }
        func artifacts(_ name: String, _ verdict: GitWorktreeSupport.Verdict) -> CleanableItem {
            let report = WorktreeArtifactsReport(
                worktreePath: "/nonexistent/r/wt/\(name)", repositoryPath: "/nonexistent/r", branch: name, head: nil,
                worktreeVerdict: verdict, folders: [WorktreeArtifactFolder(relativePath: "node_modules", bytes: 4_096)]
            )
            var row = plain("Artifacts in \(name)", WorktreeArtifactSupport.rowPath(forWorktree: report.worktreePath), .gitWorktrees)
            row.worktreeArtifacts = report
            return row
        }
        let realHome = AIAgentDataSupport.canonicalHomeDirectory(FileManager.default.homeDirectoryForCurrentUser)
        func agent(_ relative: String) -> CleanableItem {
            plain(relative, realHome.appendingPathComponent(relative).path, .aiAgentData)
        }

        let skipped: [String: CleanableItem] = [
            "docker volumes": plain("Unused volumes", DockerSupport.actionPath(for: .unusedVolumes), .dockerCache),
            "maven": plain("Maven", "/nonexistent/home/.m2/repository", .devToolCaches, byHand: true),
            "nuget": plain("NuGet", "/nonexistent/home/.nuget/packages", .devToolCaches, byHand: true),
            "ollama model": plain("qwen", CleanableItem.ollamaModelPathPrefix + "qwen:7b#0123456789abcdef", .localAIModels, byHand: true),
            "hugging face repo": plain("org/name", "/nonexistent/hub/models--org--name", .localAIModels, byHand: true),
            "protected worktree": worktree("protected", .init(status: .protected, reasons: [.trackedChanges(1)])),
            "orphan worktree": worktree("orphan", .init(status: .orphan, reasons: [.notListedByGit])),
            "artifacts of a busy worktree": artifacts("busy", .init(status: .protected, reasons: [.inUse])),
            "artifacts of an open worktree": artifacts("open", .init(status: .needsReview, reasons: [.untrackedFiles(1)])),
            "agent row of a running app": agent("Library/Application Support/Claude/Cache"),
        ]
        let controls: [String: CleanableItem] = [
            "docker image prune": plain("Unused images", DockerSupport.actionPath(for: .unusedImages), .dockerCache),
            "devtool cache": plain("Bun", "/nonexistent/home/.bun/install/cache", .devToolCaches),
            "safe worktree": worktree("safe", .init(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)])),
            "agent row of an idle app": agent("Library/Application Support/Cursor/CachedExtensionVSIXs"),
        ]

        let state = AppState(performStartupTasks: false, settingsDefaults: .isolatedForTests)
        state.scanState = .completed
        for item in Array(skipped.values) + Array(controls.values) {
            var result = state.categoryResults[item.category]
                ?? CategoryResult(category: item.category, items: [], totalSize: 0)
            result.items.append(item)
            result.totalSize += item.sizeInCategoryTotal
            state.categoryResults[item.category] = result
        }
        state.setRunningAIAgentOwners([.claudeDesktop])
        return (state, skipped, controls)
    }

    @MainActor
    func testTheBulkRuleSkipsEveryHandOnlyBlockedAndRunningAppRow() {
        let (state, skipped, controls) = makeRows()
        for (name, item) in skipped {
            XCTAssertTrue(state.isExcludedFromBulkSelection(item), name)
        }
        for (name, item) in controls {
            XCTAssertFalse(state.isExcludedFromBulkSelection(item), name)
        }
        // The static part of the rule lives on the row; only the running-app block needs AppState.
        XCTAssertTrue(skipped["docker volumes"]!.isExcludedFromBulkSelection)
        XCTAssertTrue(skipped["maven"]!.isExcludedFromBulkSelection)
        XCTAssertTrue(skipped["ollama model"]!.isExcludedFromBulkSelection)
        XCTAssertTrue(skipped["protected worktree"]!.isExcludedFromBulkSelection)
        XCTAssertTrue(skipped["artifacts of a busy worktree"]!.isExcludedFromBulkSelection)
        XCTAssertTrue(skipped["artifacts of an open worktree"]!.isExcludedFromBulkSelection)
        XCTAssertFalse(skipped["agent row of a running app"]!.isExcludedFromBulkSelection)
        XCTAssertFalse(controls["docker image prune"]!.isExcludedFromBulkSelection)
    }

    @MainActor
    func testSelectAllInCategorySkipsThemAndKeepsTheControls() {
        let (state, skipped, controls) = makeRows()
        for category in CleaningCategory.allCases { state.selectAllInCategory(category) }
        for (name, item) in skipped { XCTAssertFalse(state.isItemSelected(item), name) }
        for (name, item) in controls { XCTAssertTrue(state.isItemSelected(item), name) }
    }

    @MainActor
    func testSelectVisibleAndSetSelectionSkipThem() {
        let (state, skipped, controls) = makeRows()
        // "Select visible" calls setSelection(true, for: the rows isExcludedFromBulkSelection leaves).
        // Calling it with every row, as a stale or forged list would, must still skip the excluded ones.
        state.setSelection(true, for: Array(skipped.values) + Array(controls.values))
        for (name, item) in skipped { XCTAssertFalse(state.isItemSelected(item), name) }
        for (name, item) in controls { XCTAssertTrue(state.isItemSelected(item), name) }
    }

    @MainActor
    func testCategoryCheckboxSkipsHandOnlyRows() {
        let (state, skipped, controls) = makeRows()
        for category in [CleaningCategory.devToolCaches] {
            let binding = state.categoryBinding(for: category)
            binding.wrappedValue = true
            XCTAssertTrue(state.isItemSelected(controls["devtool cache"]!))
            XCTAssertFalse(state.isItemSelected(skipped["maven"]!))
            XCTAssertFalse(state.isItemSelected(skipped["nuget"]!))
        }
        // Categories in set (b) have no Overview checkbox at all: it never selects anything.
        for category in CleaningCategory.overviewExcluded {
            let binding = state.categoryBinding(for: category)
            XCTAssertFalse(binding.wrappedValue, category.rawValue)
            binding.wrappedValue = true
        }
        for (name, item) in skipped where item.category != .devToolCaches {
            XCTAssertFalse(state.isItemSelected(item), name)
        }
        XCTAssertFalse(state.isItemSelected(controls["docker image prune"]!))
        XCTAssertFalse(state.isItemSelected(controls["safe worktree"]!))
        XCTAssertFalse(state.isItemSelected(controls["agent row of an idle app"]!))
    }

    @MainActor
    func testPerRowToggleKeepsItsOwnBlockRules() {
        let (state, skipped, _) = makeRows()
        // A click selects rows that only need an explicit click ...
        for name in ["docker volumes", "maven", "nuget", "ollama model", "hugging face repo", "artifacts of an open worktree"] {
            let item = skipped[name]!
            state.toggleItem(item)
            XCTAssertTrue(state.isItemSelected(item), name)
        }
        // ... but never rows that cannot be removed at all.
        for name in ["protected worktree", "orphan worktree", "artifacts of a busy worktree", "agent row of a running app"] {
            let item = skipped[name]!
            state.toggleItem(item)
            XCTAssertFalse(state.isItemSelected(item), name)
        }
    }

    @MainActor
    func testClearingTheSelectionStillWorksForHandSelectedRows() {
        let (state, skipped, _) = makeRows()
        let maven = skipped["maven"]!
        state.toggleItem(maven)
        XCTAssertTrue(state.isItemSelected(maven))
        state.setSelection(false, for: [maven])
        XCTAssertFalse(state.isItemSelected(maven), "deselecting in bulk is not restricted")
    }

    @MainActor
    func testTheOverviewNeverCountsOrCleansTheExcludedCategoriesEvenWhenEverythingIsSelected() {
        let (state, skipped, controls) = makeRows()
        // Select every row by hand, as a user clicking each one would.
        for item in Array(skipped.values) + Array(controls.values) { state.toggleItem(item) }

        let overview = state.overviewSelectedItems
        XCTAssertFalse(overview.isEmpty)
        for item in overview {
            XCTAssertFalse(CleaningCategory.overviewExcluded.contains(item.category), item.name)
            XCTAssertTrue(CleaningCategory.smartScannable.contains(item.category), item.name)
        }
        XCTAssertEqual(state.totalSelectedSize, overview.reduce(0) { $0 + $1.size })

        // cleanAll (manual and scheduled) leaves the app idle when only excluded categories hold selections.
        for category in CleaningCategory.allCases where !CleaningCategory.overviewExcluded.contains(category) {
            state.categoryResults.removeValue(forKey: category)
        }
        state.cleanAll()
        XCTAssertEqual(state.scanState, .completed)
        state.cleanAll(scheduled: true)
        XCTAssertEqual(state.scanState, .completed)
    }

    @MainActor
    func testTotalsCountOnlySetA() {
        let (state, _, _) = makeRows()
        let expected = state.categoryResults
            .filter { CleaningCategory.smartScannable.contains($0.key) }
            .values.reduce(0) { $0 + $1.itemCount }
        XCTAssertEqual(state.totalItemCount, expected)
        XCTAssertEqual(state.allResults.map(\.category).filter { !CleaningCategory.smartScannable.contains($0) }, [])
    }
}

/// The Docker/OrbStack deny list runs before every deletion route's own
/// allow-list or validation. Every test here points a category at Docker's VM
/// disk (inside a fixture home) and expects the file to survive with a
/// Docker-specific refusal.
final class DeletionDenyListTests: XCTestCase {
    private let fileManager = FileManager.default
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? fileManager.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private struct Fixture {
        let home: URL
        let diskImage: URL
        let container: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = fileManager.temporaryDirectory.appendingPathComponent("puremac-deny-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let home = root.appendingPathComponent("home", isDirectory: true).resolvingSymlinksInPath()
        let container = home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true)
        let disk = container.appendingPathComponent("Data/vms/0/data", isDirectory: true)
        try fileManager.createDirectory(at: disk, withIntermediateDirectories: true)
        let image = disk.appendingPathComponent("Docker.raw")
        try Data(count: 4_096).write(to: image)
        return Fixture(home: home, diskImage: image, container: container)
    }

    private func engine(_ home: URL, trashed: Trashed = Trashed()) -> CleaningEngine {
        CleaningEngine(
            homeDirectory: home,
            isAIAgentOwnerRunning: { _ in false },
            trashOperation: { url in
                trashed.urls.append(url)
                return nil
            }
        )
    }

    /// Records every URL a route tried to move to the Trash.
    private final class Trashed: @unchecked Sendable {
        var urls: [URL] = []
    }

    private func row(_ category: CleaningCategory, _ path: String) -> CleanableItem {
        CleanableItem(name: "denied", path: path, size: 4_096, category: category, isSelected: true, lastModified: nil)
    }

    func testGenericUserPassRefusesDockerDiskAndItsParents() async throws {
        let fixture = try makeFixture()
        let engine = engine(fixture.home)
        for path in [fixture.diskImage.path, fixture.container.path, fixture.home.appendingPathComponent("Library/Containers").path] {
            let result = await engine.cleanItems([row(.userCache, path)]) { _ in }
            XCTAssertEqual(result.itemsCleaned, 0, path)
            XCTAssertTrue(result.errors.contains { $0.hasPrefix("Skipped symlink or unsafe path") }, "\(path): \(result.errors)")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testAdminPassRefusesDockerDisk() async throws {
        let fixture = try makeFixture()
        let result = await engine(fixture.home).cleanWithAdminPrivileges(items: [row(.systemJunk, fixture.diskImage.path)])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testDeveloperToolCachesRouteRefusesDockerDisk() async throws {
        let fixture = try makeFixture()
        let result = await engine(fixture.home).cleanItems([row(.devToolCaches, fixture.diskImage.path)]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testLocalAIModelsRouteChecksTheDenyListFirst() async throws {
        let fixture = try makeFixture()
        var item = row(.localAIModels, fixture.diskImage.path)
        item.isSelected = false
        let result = await engine(fixture.home).cleanItems([item]) { _ in }
        XCTAssertEqual(result.errors, [CleaningEngine.dockerDiskStateRefusal(fixture.diskImage.path)])
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testAIAgentDataTrashRouteChecksTheDenyListFirst() async throws {
        let fixture = try makeFixture()
        let trashed = Trashed()
        let result = await engine(fixture.home, trashed: trashed).cleanItems([row(.aiAgentData, fixture.diskImage.path)]) { _ in }
        XCTAssertEqual(result.errors, [CleaningEngine.dockerDiskStateRefusal(fixture.diskImage.path)])
        XCTAssertTrue(trashed.urls.isEmpty, "nothing was handed to the Trash")
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testNothingIsHandedToTheTrashForDockerDisk() async throws {
        let fixture = try makeFixture()
        let trashed = Trashed()
        // Xcode Junk is the category that can reach the Trash operation; aimed at the VM disk it is refused first.
        let result = await engine(fixture.home, trashed: trashed).cleanItems([row(.xcodeJunk, fixture.diskImage.path)]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(trashed.urls.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testWorktreeRemovalChecksTheDenyListFirst() async throws {
        let fixture = try makeFixture()
        var item = row(.gitWorktrees, fixture.container.path)
        item.gitWorktree = GitWorktreeReport(
            path: item.path, repositoryPath: "/nonexistent/repo", branch: "x", head: nil,
            verdict: .init(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)]), lastActivity: nil
        )
        let result = await engine(fixture.home).cleanItems([item]) { _ in }
        XCTAssertEqual(result.errors, [CleaningEngine.dockerDiskStateRefusal(item.path)])
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testWorktreeArtifactsChecksTheDenyListFirst() async throws {
        let fixture = try makeFixture()
        let report = WorktreeArtifactsReport(
            worktreePath: fixture.container.path, repositoryPath: "/nonexistent/repo", branch: "x", head: nil,
            worktreeVerdict: .init(status: .needsReview, reasons: [.untrackedFiles(1)]),
            folders: [WorktreeArtifactFolder(relativePath: "node_modules", bytes: 4_096)]
        )
        var item = row(.gitWorktrees, WorktreeArtifactSupport.rowPath(forWorktree: report.worktreePath))
        item.worktreeArtifacts = report
        let result = await engine(fixture.home).cleanItems([item]) { _ in }
        XCTAssertEqual(result.errors, [CleaningEngine.dockerDiskStateRefusal(report.worktreePath)])
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testDockerCacheFoldersStayCleanable() async throws {
        let fixture = try makeFixture()
        let cache = fixture.container.appendingPathComponent("Data/cache", isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 128).write(to: cache.appendingPathComponent("blob"))
        let result = await engine(fixture.home).cleanItems([row(.dockerCache, cache.path)]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertFalse(fileManager.fileExists(atPath: cache.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.diskImage.path))
    }

    func testIsDockerDiskStateCoversDiskParentsAndSymlinkSpellings() async throws {
        let fixture = try makeFixture()
        let engine = engine(fixture.home)
        let denied = [
            fixture.diskImage.path,
            fixture.container.path,
            fixture.container.appendingPathComponent("Data").path,
            fixture.container.appendingPathComponent("Data/vms/../vms/0").path,
            fixture.home.appendingPathComponent("Library/Containers").path,
            fixture.home.appendingPathComponent(".orbstack/data/data.img").path,
        ]
        for path in denied {
            let isDenied = await engine.isDockerDiskState(path)
            XCTAssertTrue(isDenied, path)
        }
        let allowed = [
            fixture.container.appendingPathComponent("Data/cache").path,
            fixture.home.appendingPathComponent("Library/Caches/example").path,
        ]
        for path in allowed {
            let isDenied = await engine.isDockerDiskState(path)
            XCTAssertFalse(isDenied, path)
        }
    }
}
