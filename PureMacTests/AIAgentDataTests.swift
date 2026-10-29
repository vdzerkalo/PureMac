import XCTest
@testable import PureMac

final class AIAgentDataTests: XCTestCase {
    private let fileManager = FileManager.default
    private var homes: [URL] = []
    private var trashed: [String] = []

    override func tearDown() {
        // Only fixtures this test created: its temp homes and the exact Trash
        // paths FileManager.trashItem returned for them.
        for path in trashed { try? fileManager.removeItem(atPath: path) }
        for home in homes { try? fileManager.removeItem(at: home) }
        trashed = []
        homes = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeHome() throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-AIAgent-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        homes.append(home)
        return AIAgentDataSupport.canonicalHomeDirectory(home)
    }

    @discardableResult
    private func write(_ home: URL, _ relative: String, bytes: Int = 1_300_000) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    private let support = "Library/Application Support"

    /// One fixture per allowlisted shape, plus decoys that must never appear.
    private func makeFullFixture() throws -> URL {
        let home = try makeHome()
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img.zst", bytes: 2_048)
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/sessiondata.img")
        try write(home, "\(support)/Claude/simulator-builds/4d775ddc1b2c0515/DerivedData/Build/product")
        try write(home, "\(support)/Claude/simulator-builds/4d775ddc1b2c0515/logs/build.log")
        try write(home, "\(support)/Claude/Cache/Cache_Data/f_000001")
        try write(home, "\(support)/Claude/Code Cache/js/entry")
        try write(home, "\(support)/Claude/local-agent-mode-sessions/session.json")
        try write(home, ".codex/.tmp/plugins-backup-837JbA/plugins/a")
        try write(home, ".codex/.tmp/plugins/active/a")
        try write(home, ".codex/auth.json")
        try write(home, ".codex/thread_history_1.sqlite")
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid/1.jpg")
        try write(home, ".gemini/antigravity-backup/mcp_config.json")
        try write(home, ".gemini/antigravity/browser_recordings/uuid/1.jpg")
        try write(home, ".gemini/oauth_creds.json")
        try write(home, "\(support)/Cursor/CachedExtensionVSIXs/ext.vsix")
        try write(home, "\(support)/Cursor/snapshots/stores/x/objects/blob")
        try write(home, "\(support)/Cursor/User/settings.json")
        return home
    }

    private func relativePaths(_ items: [CleanableItem], home: URL) -> Set<String> {
        Set(items.map { String($0.path.dropFirst(home.path.count + 1)) })
    }

    private func item(_ home: URL, _ relative: String, size: Int64 = 1_300_000) -> CleanableItem {
        CleanableItem(
            name: relative,
            path: home.appendingPathComponent(relative).path,
            size: size,
            category: .aiAgentData,
            isSelected: true,
            lastModified: nil
        )
    }

    // MARK: - Scan

    func testScanListsOnlyAllowlistedShapesAndLeavesEveryRowUnselected() async throws {
        let home = try makeFullFixture()
        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertEqual(result.category, .aiAgentData)
        XCTAssertEqual(relativePaths(result.items, home: home), [
            "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img",
            "\(support)/Claude/simulator-builds/4d775ddc1b2c0515/DerivedData",
            "\(support)/Claude/Cache",
            "\(support)/Claude/Code Cache",
            ".codex/.tmp/plugins-backup-837JbA",
            ".gemini/antigravity-backup/browser_recordings",
            "\(support)/Cursor/CachedExtensionVSIXs",
        ])
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelected && $0.category == .aiAgentData })
        XCTAssertTrue(result.items.allSatisfy { ($0.detail ?? "").isEmpty == false })
        XCTAssertEqual(result.totalSize, result.items.reduce(0) { $0 + $1.size })
    }

    func testScanNeverProducesClaudeCodeDataEvenWhenItIsHuge() async throws {
        let home = try makeFullFixture()
        try write(home, ".claude/projects/p/session.jsonl", bytes: 5_000_000)
        try write(home, ".claude/worktrees/w/big.bin", bytes: 5_000_000)
        try write(home, ".claude.json", bytes: 2_000_000)

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertFalse(result.items.contains { $0.path.contains("/.claude") })
    }

    func testRootfsIsOnlyListedWhenItsCompressedSourceExists() async throws {
        let home = try makeHome()
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")

        let withoutSource = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertTrue(withoutSource.items.isEmpty)

        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img.zst", bytes: 2_048)
        let withSource = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertEqual(withSource.items.count, 1)
    }

    func testAntigravityBackupIsOnlyListedWhenTheLiveCopyExists() async throws {
        let home = try makeHome()
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid/1.jpg")

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertTrue(result.items.isEmpty)
    }

    func testSmallItemsAreSkipped() async throws {
        let home = try makeHome()
        try write(home, "\(support)/Claude/Cache/Cache_Data/f", bytes: 4_096)

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertTrue(result.items.isEmpty)
    }

    func testSymlinkedCandidatesAreNotScanned() async throws {
        let home = try makeHome()
        let outside = try makeHome()
        try write(outside, "payload/big.bin")
        try fileManager.createDirectory(
            at: home.appendingPathComponent("\(support)/Claude"),
            withIntermediateDirectories: true
        )
        // The candidate itself is a symlink.
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("\(support)/Claude/Cache"),
            withDestinationURL: outside.appendingPathComponent("payload")
        )
        // A parent of a candidate is a symlink.
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("\(support)/Cursor"),
            withDestinationURL: outside
        )
        try write(outside, "CachedExtensionVSIXs/ext.vsix")

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertTrue(result.items.isEmpty, "scanned: \(result.items.map(\.path))")
    }

    // MARK: - Shapes

    func testRuleShapesAreExact() throws {
        let home = try makeHome()
        func rule(_ relative: String) -> AIAgentDataSupport.Rule? {
            AIAgentDataSupport.rule(forPath: home.appendingPathComponent(relative).path, homeDirectory: home)
        }
        XCTAssertNotNil(rule("\(support)/Claude/simulator-builds/4d775ddc1b2c0515/DerivedData"))
        XCTAssertNil(rule("\(support)/Claude/simulator-builds/NOTHEX/DerivedData"))
        XCTAssertNil(rule("\(support)/Claude/simulator-builds/4d775ddc1b2c0515/DerivedData/Build"))
        XCTAssertNil(rule("\(support)/Claude/simulator-builds/4d775ddc1b2c0515/logs"))
        XCTAssertNil(rule("\(support)/Claude/Cache/Cache_Data"))
        XCTAssertNil(rule("\(support)/Claude"))
        XCTAssertNil(rule("\(support)/Claude/vm_bundles/claudevm.bundle/sessiondata.img"))
        XCTAssertNil(rule("\(support)/Claude/vm_bundles"))
        XCTAssertNotNil(rule(".codex/.tmp/plugins-backup-837JbA"))
        XCTAssertNil(rule(".codex/.tmp/plugins-backup-837Jb"))
        XCTAssertNil(rule(".codex/.tmp/plugins-backup-837JbA/plugins"))
        XCTAssertNil(rule(".codex/.tmp/plugins"))
        XCTAssertNil(rule(".codex/auth.json"))
        XCTAssertNil(rule(".gemini/antigravity-backup"))
        XCTAssertNil(rule(".gemini/antigravity-backup/mcp_config.json"))
        XCTAssertNil(rule(".gemini/oauth_creds.json"))
        XCTAssertNil(rule("\(support)/Cursor/snapshots"))
        XCTAssertNil(rule(".claude"))
        XCTAssertNil(rule(".claude/worktrees"))
        XCTAssertNil(AIAgentDataSupport.rule(forPath: "/etc/hosts", homeDirectory: home))
    }

    // MARK: - Running apps

    func testProcessProbeMatchesByExecutablePathPrefix() throws {
        // The test runner is itself a running process with a known path.
        let runner = try XCTUnwrap(Bundle.main.executablePath)
        let directory = (runner as NSString).deletingLastPathComponent + "/"

        XCTAssertTrue(AIAgentDataSupport.anyProcess(withExecutablePrefixes: [directory]))
        XCTAssertFalse(AIAgentDataSupport.anyProcess(withExecutablePrefixes: ["/nonexistent-\(UUID().uuidString)/"]))
    }

    func testOwnersMatchProcessesByPathNotByName() throws {
        let home = try makeHome()
        let prefixes = AIAgentDataSupport.Owner.claudeDesktop.executablePathPrefixes(home: home.path)

        XCTAssertTrue(prefixes.contains("/Applications/Claude.app/"))
        XCTAssertTrue(prefixes.contains("\(home.path)/Library/Application Support/Claude/"))
        // A terminal Claude Code CLI lives outside these prefixes, so it must not block Claude Desktop rows.
        XCTAssertFalse(prefixes.contains { "\(home.path)/.local/share/claude/versions/1".hasPrefix($0) })
    }

    // MARK: - Review-only wiring

    func testCategoryIsReviewOnlyAndOutsideSmartScanAndSchedules() {
        XCTAssertTrue(CleaningCategory.scannable.contains(.aiAgentData))
        XCTAssertTrue(CleaningCategory.reviewOnly.contains(.aiAgentData))
        XCTAssertFalse(CleaningCategory.smartScannable.contains(.aiAgentData))
        XCTAssertFalse(ScheduleConfig().categoriesToScan.contains(.aiAgentData))
    }

    @MainActor
    func testCleanAllAndTotalsIgnoreReviewOnlyResults() {
        let state = AppState(performStartupTasks: false)
        let selected = CleanableItem(
            name: "x",
            path: "/tmp/does-not-matter",
            size: 5_000_000,
            category: .aiAgentData,
            isSelected: true,
            lastModified: nil
        )
        state.categoryResults[.aiAgentData] = CategoryResult(
            category: .aiAgentData, items: [selected], totalSize: selected.size
        )

        XCTAssertTrue(state.allResults.isEmpty)
        XCTAssertEqual(state.totalSelectedSize, 0)
        XCTAssertEqual(state.totalItemCount, 0)
    }

    // MARK: - Removal

    func testRemovalMovesToTrashAndRevalidatesTwice() async throws {
        let home = try makeFullFixture()
        var checks = 0
        let engine = CleaningEngine(homeDirectory: home) { _ in
            checks += 1
            return false
        }
        let target = item(home, "\(support)/Cursor/CachedExtensionVSIXs")

        let result = await engine.cleanItems([target]) { _ in }
        trashed.append(contentsOf: result.trashedPaths)

        XCTAssertEqual(result.itemsCleaned, 1, "errors: \(result.errors)")
        XCTAssertEqual(result.trashedPaths.count, 1)
        XCTAssertTrue(result.trashedPaths.allSatisfy { fileManager.fileExists(atPath: $0) })
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertGreaterThanOrEqual(checks, 2, "the running check must run before and right before the move")
        // Siblings in the same app folder are untouched.
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent("\(support)/Cursor/User/settings.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent("\(support)/Cursor/snapshots/stores/x/objects/blob").path))
    }

    func testRemovalIsBlockedWhileTheOwningAppRuns() async throws {
        let home = try makeFullFixture()
        var asked: [AIAgentDataSupport.Owner] = []
        let engine = CleaningEngine(homeDirectory: home) { owner in
            asked.append(owner)
            return owner == .claudeDesktop
        }
        let blocked = item(home, "\(support)/Claude/Cache")
        let allowed = item(home, ".codex/.tmp/plugins-backup-837JbA")

        let result = await engine.cleanItems([blocked, allowed]) { _ in }
        trashed.append(contentsOf: result.trashedPaths)

        XCTAssertTrue(fileManager.fileExists(atPath: blocked.path))
        XCTAssertFalse(fileManager.fileExists(atPath: allowed.path))
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.contains { $0.contains("Claude Desktop is running") }, "\(result.errors)")
        XCTAssertFalse(result.cleanedPaths.contains(blocked.path))
        XCTAssertTrue(asked.contains(.claudeDesktop))
        XCTAssertTrue(asked.contains(.codex))
    }

    func testSymlinkedCandidateIsRefusedAndTargetSurvives() async throws {
        let home = try makeHome()
        let outside = try makeHome()
        let marker = try write(outside, "payload/must-survive")
        try fileManager.createDirectory(
            at: home.appendingPathComponent("\(support)/Claude"),
            withIntermediateDirectories: true
        )
        let link = home.appendingPathComponent("\(support)/Claude/Cache")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("payload"))
        let engine = CleaningEngine(homeDirectory: home) { _ in false }

        let result = await engine.cleanItems([item(home, "\(support)/Claude/Cache")]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.trashedPaths.isEmpty)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), outside.appendingPathComponent("payload").path)
    }

    func testSymlinkedParentIsRefused() async throws {
        let home = try makeHome()
        let outside = try makeHome()
        let marker = try write(outside, "CachedExtensionVSIXs/must-survive")
        try fileManager.createDirectory(
            at: home.appendingPathComponent(support),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("\(support)/Cursor"),
            withDestinationURL: outside
        )
        let engine = CleaningEngine(homeDirectory: home) { _ in false }

        let result = await engine.cleanItems([item(home, "\(support)/Cursor/CachedExtensionVSIXs")]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    }

    func testClaudeCodeDataIsNeverRemovedEvenWhenTheItemIsForged() async throws {
        let home = try makeHome()
        let projects = try write(home, ".claude/projects/p/session.jsonl", bytes: 5_000_000)
        let worktrees = try write(home, ".claude/worktrees/w/big.bin", bytes: 5_000_000)
        let config = try write(home, ".claude.json", bytes: 2_000_000)
        let engine = CleaningEngine(homeDirectory: home) { _ in false }
        let forged = [
            item(home, ".claude"),
            item(home, ".claude/projects"),
            item(home, ".claude/worktrees/w"),
            item(home, ".claude.json"),
        ]

        let result = await engine.cleanItems(forged) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.trashedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, forged.count)
        for url in [projects, worktrees, config] {
            XCTAssertTrue(fileManager.fileExists(atPath: url.path), "\(url.path) must survive")
        }
    }

    func testPathsOutsideTheAllowlistAreRefusedEvenInsideAnAllowlistedAppFolder() async throws {
        let home = try makeFullFixture()
        let engine = CleaningEngine(homeDirectory: home) { _ in false }
        let forged = [
            item(home, "\(support)/Claude/vm_bundles/claudevm.bundle/sessiondata.img"),
            item(home, "\(support)/Claude/vm_bundles"),
            item(home, "\(support)/Claude/local-agent-mode-sessions"),
            item(home, ".codex/auth.json"),
            item(home, ".codex/.tmp/plugins"),
            item(home, ".gemini/oauth_creds.json"),
            item(home, ".gemini/antigravity-backup/mcp_config.json"),
            item(home, "\(support)/Cursor/snapshots"),
            item(home, "\(support)/Cursor/Cache/../User"),
        ]

        let result = await engine.cleanItems(forged) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.trashedPaths.isEmpty)
        for entry in forged where !entry.path.contains("..") {
            XCTAssertTrue(fileManager.fileExists(atPath: entry.path), "\(entry.path) must survive")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent("\(support)/Cursor/User/settings.json").path))
    }

    func testRootfsWithoutItsCompressedSourceIsRefused() async throws {
        let home = try makeHome()
        let rootfs = try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")
        let engine = CleaningEngine(homeDirectory: home) { _ in false }

        let result = await engine.cleanItems(
            [item(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")]
        ) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: rootfs.path))
    }

    func testAlreadyGoneItemIsNotCountedAsFreedSpace() async throws {
        let home = try makeHome()
        let engine = CleaningEngine(homeDirectory: home) { _ in false }
        let gone = item(home, "\(support)/Cursor/CachedExtensionVSIXs")

        let result = await engine.cleanItems([gone]) { _ in }

        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.cleanedPaths.contains(gone.path))
    }

    func testAdministratorCleaningNeverEscalatesAIAgentData() async throws {
        let home = try makeFullFixture()
        let target = item(home, "\(support)/Cursor/CachedExtensionVSIXs")
        let engine = CleaningEngine(homeDirectory: home) { _ in false }

        let result = await engine.cleanWithAdminPrivileges(items: [target])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }
}
