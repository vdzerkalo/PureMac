import XCTest
@testable import PureMac

final class DockerSupportTests: XCTestCase {
    /// Captured from Docker Desktop 29 (`docker system df --format '{{json .}}'`).
    private let systemDFOutput = """
    {"Active":"7","Reclaimable":"10.68GB (61%)","Size":"17.44GB","TotalCount":"54","Type":"Images"}
    {"Active":"3","Reclaimable":"20.19MB (16%)","Size":"124.7MB","TotalCount":"8","Type":"Containers"}
    {"Active":"3","Reclaimable":"5.55GB (25%)","Size":"21.51GB","TotalCount":"25","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"11.29GB","Size":"21.19GB","TotalCount":"327","Type":"Build Cache"}
    """

    // MARK: - system df parsing

    func testParseSystemDFReadsEveryRow() {
        let rows = DockerSupport.parseSystemDF(systemDFOutput)

        XCTAssertEqual(rows, [
            .init(type: "Images", size: 17_440_000_000, reclaimable: 10_680_000_000),
            .init(type: "Containers", size: 124_700_000, reclaimable: 20_190_000),
            .init(type: "Local Volumes", size: 21_510_000_000, reclaimable: 5_550_000_000),
            .init(type: "Build Cache", size: 21_190_000_000, reclaimable: 11_290_000_000),
        ])
    }

    func testParseSystemDFSkipsMalformedLines() {
        let output = """
        WARNING: something on stdout
        {"Type":"Images"}
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
        """

        XCTAssertEqual(DockerSupport.parseSystemDF(output), [
            .init(type: "Containers", size: 0, reclaimable: 0),
        ])
    }

    func testParseSystemDFOfEmptyOutputIsEmpty() {
        XCTAssertEqual(DockerSupport.parseSystemDF(""), [])
    }

    // MARK: - prune actions

    func testPruneEstimatesGiveOneActionPerReclaimableRow() {
        let estimates = DockerSupport.pruneEstimates(DockerSupport.parseSystemDF(systemDFOutput))

        XCTAssertEqual(estimates.map { $0.action }, [.buildCache, .stoppedContainers, .unusedImages, .unusedVolumes])
        XCTAssertEqual(estimates.map { $0.bytes }, [11_290_000_000, 20_190_000, 10_680_000_000, 5_550_000_000])
    }

    func testPruneEstimatesSkipEmptyRows() {
        let rows: [DockerSupport.DiskUsageRow] = [
            .init(type: "Images", size: 1_000, reclaimable: 0),
            .init(type: "Build Cache", size: 2_000, reclaimable: 2_000),
        ]

        XCTAssertEqual(DockerSupport.pruneEstimates(rows).map { $0.action }, [.buildCache])
        XCTAssertTrue(DockerSupport.pruneEstimates([]).isEmpty)
    }

    func testPruneActionArgumentsMatchWhatDfCountsAsReclaimable() {
        // df counts every unused object, so images, volumes and build cache
        // need -a; without it only dangling objects go and the row overstates.
        XCTAssertEqual(DockerSupport.PruneAction.buildCache.arguments, ["builder", "prune", "-a", "-f"])
        XCTAssertEqual(DockerSupport.PruneAction.stoppedContainers.arguments, ["container", "prune", "-f"])
        XCTAssertEqual(DockerSupport.PruneAction.unusedImages.arguments, ["image", "prune", "-a", "-f"])
        XCTAssertEqual(DockerSupport.PruneAction.unusedVolumes.arguments, ["volume", "prune", "-a", "-f"])
        XCTAssertEqual(DockerSupport.PruneAction.unusedImages.commandLine, "docker image prune -a -f")
        for action in DockerSupport.PruneAction.allCases {
            XCTAssertFalse(action.arguments.contains("system"), "\(action) must not run a whole-system prune")
        }
    }

    func testOnlyVolumesRequireExplicitSelection() {
        let explicit = DockerSupport.PruneAction.allCases.filter(\.requiresExplicitSelection)
        XCTAssertEqual(explicit, [.unusedVolumes])
    }

    func testActionPathRoundTrips() {
        for action in DockerSupport.PruneAction.allCases {
            XCTAssertEqual(DockerSupport.action(forPath: DockerSupport.actionPath(for: action)), action)
        }
        XCTAssertNil(DockerSupport.action(forPath: "docker-prune:bogus"))
        XCTAssertNil(DockerSupport.action(forPath: "/Users/test/Library/Containers/com.docker.docker/Data/log"))
        XCTAssertNil(DockerSupport.action(forPath: ""))
    }

    func testPruneRowsAreActionItems() {
        let volumes = CleanableItem(
            name: "Unused Docker volumes",
            path: DockerSupport.actionPath(for: .unusedVolumes),
            size: 1,
            category: .dockerCache,
            isSelected: false,
            lastModified: nil
        )
        XCTAssertTrue(volumes.isActionItem)
        XCTAssertEqual(volumes.dockerPruneAction, .unusedVolumes)
        XCTAssertTrue(volumes.requiresExplicitSelection)

        // The prefix only means something inside the Docker category.
        let elsewhere = CleanableItem(
            name: "Not Docker",
            path: DockerSupport.actionPath(for: .unusedVolumes),
            size: 1,
            category: .userCache,
            isSelected: false,
            lastModified: nil
        )
        XCTAssertNil(elsewhere.dockerPruneAction)
        XCTAssertFalse(elsewhere.requiresExplicitSelection)
    }

    // MARK: - reclaimed space

    func testParseReclaimedSpaceFromPruneSummaries() {
        XCTAssertEqual(DockerSupport.parseReclaimedSpace("""
        Deleted Containers:
        4f2c1b0a9e8d

        Total reclaimed space: 20.19MB
        """), 20_190_000)
        // `docker builder prune` (buildx) ends with a tab-separated "Total:" line.
        XCTAssertEqual(DockerSupport.parseReclaimedSpace("""
        ID\t\t\t\t\t\tRECLAIMABLE\tSIZE\t\tLAST ACCESSED
        x7f2kq\t\t\t\t\t\ttrue \t\t11.29GB\t\t3 weeks ago
        Total:\t11.29GB
        """), 11_290_000_000)
        XCTAssertEqual(DockerSupport.parseReclaimedSpace("Total reclaimed space: 0B"), 0)
        XCTAssertNil(DockerSupport.parseReclaimedSpace(""))
    }

    // MARK: - Docker.raw

    func testDockerRawPathIsInsideDockerDesktopContainer() {
        XCTAssertEqual(
            DockerSupport.dockerRawPath(homeDirectory: "/Users/test"),
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        )
    }

    func testAllocatedSizeReportsBlocksNotApparentLength() throws {
        // A sparse file, like Docker.raw: huge apparent length, almost no blocks.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-DockerRaw-\(UUID().uuidString).raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1_000_000_000)
        try handle.close()

        let allocated = try XCTUnwrap(DockerSupport.allocatedSize(ofFileAt: url.path))
        XCTAssertLessThan(allocated, 1_000_000)
        XCTAssertNil(DockerSupport.allocatedSize(ofFileAt: url.path + ".missing"))
    }

    // MARK: - byte parsing

    func testParseHumanBytes() {
        XCTAssertEqual(DockerSupport.parseHumanBytes("0B"), 0)
        XCTAssertEqual(DockerSupport.parseHumanBytes("789kB"), 789_000)
        XCTAssertEqual(DockerSupport.parseHumanBytes("456MB"), 456_000_000)
        XCTAssertEqual(DockerSupport.parseHumanBytes(" 1.23GB "), 1_230_000_000)
        XCTAssertEqual(DockerSupport.parseHumanBytes("2TB"), 2_000_000_000_000)
        XCTAssertNil(DockerSupport.parseHumanBytes(""))
        XCTAssertNil(DockerSupport.parseHumanBytes("lots"))
    }

    // MARK: - CLI discovery

    func testLocateBinaryPrefersSystemLink() {
        let found = DockerSupport.locateBinary(homeDirectory: "/Users/test") { path in
            path == "/usr/local/bin/docker" || path == "/Applications/Docker.app/Contents/Resources/bin/docker"
        }

        XCTAssertEqual(found, "/usr/local/bin/docker")
    }

    func testLocateBinaryFindsDockerDesktopUserInstall() {
        let found = DockerSupport.locateBinary(homeDirectory: "/Users/test") { path in
            path == "/Users/test/.docker/bin/docker"
        }

        XCTAssertEqual(found, "/Users/test/.docker/bin/docker")
    }

    func testLocateBinaryFindsOrbStack() {
        let found = DockerSupport.locateBinary(homeDirectory: "/Users/test") { path in
            path == "/Users/test/.orbstack/bin/docker"
        }

        XCTAssertEqual(found, "/Users/test/.orbstack/bin/docker")
    }

    func testLocateBinaryFallsBackToAppBundle() {
        let found = DockerSupport.locateBinary(homeDirectory: "/Users/test") { path in
            path == "/Applications/Docker.app/Contents/Resources/bin/docker"
        }

        XCTAssertEqual(found, "/Applications/Docker.app/Contents/Resources/bin/docker")
    }

    func testLocateBinaryReturnsNilWithoutDocker() {
        XCTAssertNil(DockerSupport.locateBinary(homeDirectory: "/Users/test") { _ in false })
    }

    // MARK: - error classification

    func testIsDaemonUnavailable() {
        XCTAssertTrue(DockerSupport.isDaemonUnavailable(
            stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
        ))
        XCTAssertTrue(DockerSupport.isDaemonUnavailable(
            stderr: "error during connect: dial unix /Users/test/.docker/run/docker.sock: connect: no such file or directory"
        ))
        XCTAssertFalse(DockerSupport.isDaemonUnavailable(stderr: "unknown flag: --bogus"))
    }
}

final class RemovalRiskTests: XCTestCase {
    private func prune(_ action: DockerSupport.PruneAction, selected: Bool) -> CleanableItem {
        CleanableItem(name: action.diskUsageType, path: DockerSupport.actionPath(for: action), size: 4_096, category: .dockerCache, isSelected: selected, lastModified: nil)
    }

    func testDockerNeedsThreeAcknowledgementsAndAFourthForVolumes() {
        let cache = prune(.buildCache, selected: true)
        let volumes = prune(.unusedVolumes, selected: false)
        XCTAssertEqual(RemovalRisk.risks(for: .dockerCache, items: [cache]).count, 3)
        XCTAssertEqual(RemovalRisk.risks(for: .dockerCache, items: [cache, volumes]).count, 4)
        XCTAssertTrue(RemovalRisk.risks(for: .userCache, items: [cache]).isEmpty)
        XCTAssertFalse(RemovalRisk.requiresAcknowledgement(.userCache))
    }

    func testAgentPromptListsEveryFoundItemAndMarksProposedOnes() {
        let cache = prune(.buildCache, selected: true)
        let volumes = prune(.unusedVolumes, selected: false)
        let prompt = RemovalRisk.agentPrompt(category: .dockerCache, found: [cache, volumes], proposed: [cache.id])
        let rows = prompt.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| #") }

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].contains("| ✔ |") && rows[0].contains("`docker builder prune -a -f`"), String(rows[0]))
        XCTAssertTrue(rows[1].contains("| · |") && rows[1].contains("`docker volume prune -a -f`") && rows[1].contains("erases data"), String(rows[1]))
        XCTAssertTrue(prompt.contains("Read-only: do not delete"))
        XCTAssertTrue(prompt.contains("No sub-agents"))
        XCTAssertTrue(prompt.contains("Proposed: 1 of 2 items"))
    }
}
