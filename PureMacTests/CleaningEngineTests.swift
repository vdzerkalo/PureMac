import XCTest
@testable import PureMac

final class CleaningEngineTests: XCTestCase {
    private let fileManager = FileManager.default
    private var fixtureHome: URL!
    private var fixtureRoot: URL!
    private var savedExclusions: [String]?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedExclusions = UserDefaults.standard.stringArray(forKey: CleanupExclusions.defaultsKey)
        UserDefaults.standard.set([], forKey: CleanupExclusions.defaultsKey)
        // A temp home: the engine's allow-list roots resolve under it, so no
        // test reads, writes or deletes anything in the real home or Trash.
        fixtureHome = fileManager.temporaryDirectory
            .appendingPathComponent("PureMac-CleaningEngine-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        fixtureRoot = fixtureHome.appendingPathComponent("Library/Caches/PureMacTests")
        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureHome {
            try? fileManager.removeItem(at: fixtureHome)
        }
        if let savedExclusions {
            UserDefaults.standard.set(savedExclusions, forKey: CleanupExclusions.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CleanupExclusions.defaultsKey)
        }
        try super.tearDownWithError()
    }

    func testMissingFileIsHandledWithoutClaimingFreedSpace() async {
        let path = fixtureRoot.appendingPathComponent("already-gone").path
        let item = makeItem(path: path, size: 4096)

        let result = await makeEngine().cleanItems([item]) { _ in }

        XCTAssertTrue(result.cleanedPaths.contains(path))
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testProgressAdvancesAfterDeletionFinishes() async throws {
        let file = fixtureRoot.appendingPathComponent("progress.bin")
        try Data(repeating: 1, count: 4096).write(to: file)
        let observed = expectation(description: "progress")

        let result = await makeEngine().cleanItems([makeItem(path: file.path, size: 4096)]) { progress in
            XCTAssertEqual(progress, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            observed.fulfill()
        }

        await fulfillment(of: [observed], timeout: 1)
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.freedSpace, 4096)
    }

    func testSymlinkIsRefusedWithoutDeletingItsTarget() async throws {
        let target = fixtureRoot.appendingPathComponent("target.bin")
        let link = fixtureRoot.appendingPathComponent("linked.bin")
        try Data(repeating: 2, count: 4096).write(to: target)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let result = await makeEngine().cleanItems([makeItem(path: link.path, size: 4096)]) { _ in }

        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
        XCTAssertFalse(result.cleanedPaths.contains(link.path))
        XCTAssertTrue(result.errors.contains { $0.localizedCaseInsensitiveContains("symlink") })
    }

    func testSymlinkedParentIsRefusedWithoutDeletingItsTarget() async throws {
        let targetDirectory = fixtureRoot.appendingPathComponent("target-directory")
        let target = targetDirectory.appendingPathComponent("target.bin")
        let linkedDirectory = fixtureRoot.appendingPathComponent("linked-directory")
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 4096).write(to: target)
        try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)
        let linkedTarget = linkedDirectory.appendingPathComponent("target.bin")

        let result = await makeEngine().cleanItems([makeItem(path: linkedTarget.path, size: 4096)]) { _ in }

        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
        XCTAssertFalse(result.cleanedPaths.contains(linkedTarget.path))
        XCTAssertTrue(result.errors.contains { $0.localizedCaseInsensitiveContains("symlink") })
    }

    func testDanglingSymlinkIsRefusedInsteadOfReportedAsCleaned() async throws {
        let target = fixtureRoot.appendingPathComponent("missing-target.bin")
        let link = fixtureRoot.appendingPathComponent("dangling.bin")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let result = await makeEngine().cleanItems([makeItem(path: link.path, size: 4096)]) { _ in }

        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
        XCTAssertFalse(result.cleanedPaths.contains(link.path))
        XCTAssertTrue(result.errors.contains { $0.localizedCaseInsensitiveContains("symlink") })
    }

    func testExcludedFileIsNeverDeleted() async throws {
        let file = fixtureRoot.appendingPathComponent("excluded.bin")
        try Data(repeating: 3, count: 4096).write(to: file)
        CleanupExclusions.add(file.path)

        let result = await makeEngine().cleanItems([makeItem(path: file.path, size: 4096)]) { _ in }

        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
        XCTAssertFalse(result.cleanedPaths.contains(file.path))
        XCTAssertEqual(result.errors, ["Excluded from cleanup: excluded.bin"])
    }

    func testAppModifyingCategoriesNeverFallThroughToFileDeletion() async throws {
        let app = fixtureRoot.appendingPathComponent("Protected.app")
        let localization = fixtureRoot.appendingPathComponent("fr.lproj")
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localization, withIntermediateDirectories: true)

        let items = [
            makeItem(path: app.path, size: 4096, category: .universalBinaries),
            makeItem(path: localization.path, size: 4096, category: .languageFiles),
        ]
        let result = await makeEngine().cleanItems(items) { _ in }

        XCTAssertTrue(fileManager.fileExists(atPath: app.path))
        XCTAssertTrue(fileManager.fileExists(atPath: localization.path))
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 2)
    }

    private func makeEngine() -> CleaningEngine {
        CleaningEngine(homeDirectory: fixtureHome, trashOperation: FakeTrash.operation(in: fixtureHome))
    }

    private func makeItem(
        path: String,
        size: Int64,
        category: CleaningCategory = .userCache
    ) -> CleanableItem {
        CleanableItem(
            name: (path as NSString).lastPathComponent,
            path: path,
            size: size,
            category: category,
            isSelected: true,
            lastModified: nil
        )
    }
}
