import XCTest
@testable import PureMac

final class AIAgentDataTests: XCTestCase {
    private let fileManager = FileManager.default
    private var homes: [URL] = []

    override func tearDown() {
        // Only fixtures this test created. Nothing here uses the real Trash:
        // every engine gets a fake trash folder under a temp directory.
        for home in homes { try? fileManager.removeItem(at: home) }
        homes = []
        super.tearDown()
    }

    /// Engine with an injected owner check and a fake Trash (a temp folder).
    /// Returns the folder so tests can see what was "trashed".
    private func makeEngine(
        _ home: URL,
        trashFolder: URL? = nil,
        running: @escaping AIAgentDataSupport.OwnerRunningCheck = { _ in false }
    ) throws -> (engine: CleaningEngine, trash: URL) {
        let trash = try trashFolder ?? makeHome()
        let engine = CleaningEngine(
            homeDirectory: home,
            isAIAgentOwnerRunning: running,
            trashOperation: { url in
                let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
        return (engine, trash)
    }

    private func age(_ url: URL, hours: Double) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-hours * 3600)],
            ofItemAtPath: url.path
        )
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
        let backup = try write(home, ".codex/.tmp/plugins-backup-837JbA/plugins/a")
        try age(backup.deletingLastPathComponent().deletingLastPathComponent(), hours: 5)
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

    func testVMDiskImagesAreNeverListedEvenWithTheirCompressedSource() async throws {
        let home = try makeHome()
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img.zst")
        try write(home, "\(support)/Claude/vm_bundles/claudevm.bundle/sessiondata.img")

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertTrue(result.items.isEmpty, "scanned: \(result.items.map(\.path))")
    }

    func testAntigravityBackupIsOnlyListedWhenTheLiveCopyExists() async throws {
        let home = try makeHome()
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid/1.jpg")

        let result = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)

        XCTAssertTrue(result.items.isEmpty)
    }

    func testAntigravityBackupIsOnlyListedWhenEveryEntryExistsInTheLiveCopy() async throws {
        let home = try makeHome()
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid-a/1.jpg")
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid-b/1.jpg")
        try write(home, ".gemini/antigravity/browser_recordings/uuid-a/1.jpg")

        let missing = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertTrue(missing.items.isEmpty, "uuid-b has no live counterpart")

        try write(home, ".gemini/antigravity/browser_recordings/uuid-b/1.jpg")
        let complete = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertEqual(complete.items.count, 1)

        // A symlink in the live folder is not a copy.
        let live = home.appendingPathComponent(".gemini/antigravity/browser_recordings/uuid-b")
        try fileManager.removeItem(at: live)
        try fileManager.createSymbolicLink(at: live, withDestinationURL: home)
        let linked = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertTrue(linked.items.isEmpty)
    }

    func testAntigravityBackupIsRefusedAtRemovalWhenALiveEntryDisappears() async throws {
        let home = try makeHome()
        try write(home, ".gemini/antigravity-backup/browser_recordings/uuid-a/1.jpg")
        let live = try write(home, ".gemini/antigravity/browser_recordings/uuid-a/1.jpg")
        let target = item(home, ".gemini/antigravity-backup/browser_recordings")
        let (engine, trash) = try makeEngine(home)
        // Listed at scan time, then the live copy loses the entry.
        try fileManager.removeItem(at: live.deletingLastPathComponent())

        let result = await engine.cleanItems([target]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.contains { $0.contains("live copy") }, "\(result.errors)")
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testCodexPluginBackupIsBlockedBySyncLockAndByRecentModification() async throws {
        let home = try makeHome()
        let backup = try write(home, ".codex/.tmp/plugins-backup-AbC123/plugins/a")
        let folder = backup.deletingLastPathComponent().deletingLastPathComponent()
        let target = item(home, ".codex/.tmp/plugins-backup-AbC123")

        // Younger than one hour: not listed, refused at removal.
        let young = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertTrue(young.items.isEmpty)
        let (engine, trash) = try makeEngine(home)
        let youngResult = await engine.cleanItems([target]) { _ in }
        XCTAssertEqual(youngResult.itemsCleaned, 0)
        XCTAssertTrue(youngResult.errors.contains { $0.contains("less than an hour") }, "\(youngResult.errors)")

        // Old enough: listed.
        try age(folder, hours: 3)
        let old = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertEqual(old.items.count, 1)

        // A sync lock appears after the scan: refused at removal.
        try write(home, ".codex/.tmp/plugins.sync.lock", bytes: 0)
        let lockedResult = await engine.cleanItems([target]) { _ in }
        XCTAssertEqual(lockedResult.itemsCleaned, 0)
        XCTAssertTrue(lockedResult.errors.contains { $0.contains("sync lock") }, "\(lockedResult.errors)")
        XCTAssertTrue(fileManager.fileExists(atPath: folder.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty)
        let lockedScan = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        XCTAssertTrue(lockedScan.items.isEmpty)
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
        XCTAssertNil(rule("\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img"))
        XCTAssertNil(rule("\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img.zst"))
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

    func testLiveProcessListContainsTheRunningTestHost() throws {
        let runner = try XCTUnwrap(Bundle.main.executablePath)
        let processes = try XCTUnwrap(AIAgentDataSupport.liveProcesses())

        XCTAssertTrue(processes.contains { $0.path == runner })
    }

    func testCodexCLIIsDetectedWhereverItIsInstalled() throws {
        let home = try makeHome().path
        let codex = AIAgentDataSupport.Owner.codex
        let paths = [
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex",
            "\(home)/.nvm/versions/node/v22.1.0/lib/node_modules/@openai/codex/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.codex/packages/standalone/releases/0.165.0-aarch64-apple-darwin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ]
        for path in paths {
            XCTAssertTrue(codex.matches(.init(path: path, name: nil), home: home), path)
        }
        // The node parent of a global npm install is not itself recognisable; the codex child is.
        XCTAssertFalse(codex.matches(.init(path: "/opt/homebrew/bin/node", name: nil), home: home))
        XCTAssertFalse(codex.matches(.init(path: "/usr/bin/vim", name: nil), home: home))
    }

    func testClaudeDesktopMatchesItsManagedCLIButNotAnotherCLIInstall() throws {
        let home = try makeHome().path
        let claude = AIAgentDataSupport.Owner.claudeDesktop

        XCTAssertTrue(claude.matches(
            .init(path: "\(home)/Library/Application Support/Claude/claude-code/2.1.309/abc/claude.app/Contents/MacOS/claude", name: nil),
            home: home
        ))
        XCTAssertTrue(claude.matches(.init(path: "/Applications/Claude.app/Contents/MacOS/Claude", name: nil), home: home))
        XCTAssertFalse(claude.matches(.init(path: "\(home)/.local/share/claude/versions/1/claude", name: nil), home: home))
    }

    func testUnreadablePathFallsBackToTheProcessNameAndFailsClosed() throws {
        let home = try makeHome().path

        XCTAssertTrue(AIAgentDataSupport.Owner.claudeDesktop.matches(.init(path: nil, name: "Claude Helper (Renderer)"), home: home))
        XCTAssertTrue(AIAgentDataSupport.Owner.codex.matches(.init(path: nil, name: "codex"), home: home))
        XCTAssertTrue(AIAgentDataSupport.Owner.cursor.matches(.init(path: nil, name: "Cursor Helper"), home: home))
        XCTAssertFalse(AIAgentDataSupport.Owner.cursor.matches(.init(path: nil, name: "launchd"), home: home))
        XCTAssertFalse(AIAgentDataSupport.Owner.cursor.matches(.init(path: nil, name: nil), home: home))
    }

    // MARK: - Review-only wiring

    func testCategoryIsReviewOnlyAndOutsideSmartScanAndSchedules() {
        XCTAssertTrue(CleaningCategory.scannable.contains(.aiAgentData))
        XCTAssertTrue(CleaningCategory.smartScanExcluded.contains(.aiAgentData))
        XCTAssertFalse(CleaningCategory.smartScannable.contains(.aiAgentData))
        XCTAssertFalse(ScheduleConfig().categoriesToScan.contains(.aiAgentData))
    }

    @MainActor
    func testCleanAllAndTotalsIgnoreReviewOnlyResults() {
        let state = AppState(performStartupTasks: false, settingsDefaults: .isolatedForTests)
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

    @MainActor
    func testBulkSelectionSkipsRowsBlockedByARunningApp() {
        let state = AppState(performStartupTasks: false, settingsDefaults: .isolatedForTests)
        let realHome = AIAgentDataSupport.canonicalHomeDirectory(fileManager.homeDirectoryForCurrentUser)
        func row(_ relative: String) -> CleanableItem {
            CleanableItem(
                name: relative,
                path: realHome.appendingPathComponent(relative).path,
                size: 5_000_000,
                category: .aiAgentData,
                isSelected: false,
                lastModified: nil
            )
        }
        let claude = row("\(support)/Claude/Cache")
        let cursor = row("\(support)/Cursor/CachedExtensionVSIXs")
        state.categoryResults[.aiAgentData] = CategoryResult(
            category: .aiAgentData, items: [claude, cursor], totalSize: 10_000_000
        )
        state.setRunningAIAgentOwners([.claudeDesktop])

        state.setSelection(true, for: [claude, cursor])
        XCTAssertFalse(state.isItemSelected(claude))
        XCTAssertTrue(state.isItemSelected(cursor))

        state.deselectAllInCategory(.aiAgentData)
        state.selectAllInCategory(.aiAgentData)
        XCTAssertFalse(state.isItemSelected(claude))
        XCTAssertTrue(state.isItemSelected(cursor))

        state.toggleItem(claude)
        XCTAssertFalse(state.isItemSelected(claude))
        XCTAssertEqual(state.selectedCountInCategory(.aiAgentData), 1)

        // Selected first, app starts afterwards: the selection is dropped and does not return.
        state.setRunningAIAgentOwners([])
        state.toggleItem(claude)
        XCTAssertTrue(state.isItemSelected(claude))
        state.setRunningAIAgentOwners([.claudeDesktop])
        XCTAssertFalse(state.isItemSelected(claude))
        state.setRunningAIAgentOwners([])
        XCTAssertFalse(state.isItemSelected(claude))
    }

    // MARK: - Removal

    func testRemovalValidatesAtMoveTimeAndNeverTouchesTheRealTrash() async throws {
        let home = try makeFullFixture()
        var checks = 0
        let (engine, trash) = try makeEngine(home) { _ in
            checks += 1
            return false
        }
        let target = item(home, "\(support)/Cursor/CachedExtensionVSIXs")

        let result = await engine.cleanItems([target]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "errors: \(result.errors)")
        XCTAssertEqual(result.trashedPaths.count, 1)
        XCTAssertTrue(result.trashedPaths.allSatisfy { $0.hasPrefix(trash.path + "/") && fileManager.fileExists(atPath: $0) })
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertEqual(checks, 1, "the running check runs once, at removal time")
        // Siblings in the same app folder are untouched.
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent("\(support)/Cursor/User/settings.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: home.appendingPathComponent("\(support)/Cursor/snapshots/stores/x/objects/blob").path))
    }

    func testAppStartedAfterTheScanBlocksRemoval() async throws {
        let home = try makeFullFixture()
        let scan = await ScanEngine(homeDirectory: home).scanCategory(.aiAgentData)
        let row = try XCTUnwrap(scan.items.first { $0.path.hasSuffix("Cursor/CachedExtensionVSIXs") })
        let (engine, trash) = try makeEngine(home) { $0 == .cursor }

        let result = await engine.cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: row.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testRemovalIsBlockedWhileTheOwningAppRuns() async throws {
        let home = try makeFullFixture()
        var asked: [AIAgentDataSupport.Owner] = []
        let (engine, trash) = try makeEngine(home) { owner in
            asked.append(owner)
            return owner == .claudeDesktop
        }
        let blocked = item(home, "\(support)/Claude/Cache")
        let allowed = item(home, ".codex/.tmp/plugins-backup-837JbA")

        let result = await engine.cleanItems([blocked, allowed]) { _ in }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: trash.path).count, 1)

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
        let (engine, _) = try makeEngine(home)

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
        let (engine, _) = try makeEngine(home)

        let result = await engine.cleanItems([item(home, "\(support)/Cursor/CachedExtensionVSIXs")]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path))
    }

    func testClaudeCodeDataIsNeverRemovedEvenWhenTheItemIsForged() async throws {
        let home = try makeHome()
        let projects = try write(home, ".claude/projects/p/session.jsonl", bytes: 5_000_000)
        let worktrees = try write(home, ".claude/worktrees/w/big.bin", bytes: 5_000_000)
        let config = try write(home, ".claude.json", bytes: 2_000_000)
        let (engine, _) = try makeEngine(home)
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
        let (engine, _) = try makeEngine(home)
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

    func testVMDiskImageIsRefusedEvenWithItsCompressedSource() async throws {
        let home = try makeFullFixture()
        let rootfs = home.appendingPathComponent("\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")
        let (engine, trash) = try makeEngine(home)

        let result = await engine.cleanItems(
            [item(home, "\(support)/Claude/vm_bundles/claudevm.bundle/rootfs.img")]
        ) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: rootfs.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testAlreadyGoneItemIsNotCountedAsFreedSpace() async throws {
        let home = try makeHome()
        let (engine, _) = try makeEngine(home)
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
        let (engine, _) = try makeEngine(home)

        let result = await engine.cleanWithAdminPrivileges(items: [target])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }
}
