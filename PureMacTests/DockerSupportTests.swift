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
        XCTAssertTrue(estimates.allSatisfy { $0.sizeKnown })
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
        // Dangling-only is the narrower command: no -a, so tagged images stay.
        XCTAssertEqual(DockerSupport.PruneAction.danglingImages.arguments, ["image", "prune", "-f"])
        XCTAssertEqual(DockerSupport.PruneAction.danglingImages.commandLine, "docker image prune -f")
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

    // MARK: - dangling images

    private let usageOutput = """
    {"Images":[\
    {"Containers":"0","ID":"sha256:aaaa","Repository":"<none>","Tag":"<none>","SharedSize":"0B","Size":"631MB","UniqueSize":"630.7MB"},\
    {"Containers":"1","ID":"sha256:bbbb","Repository":"<none>","Tag":"<none>","SharedSize":"0B","Size":"100MB","UniqueSize":"100MB"},\
    {"Containers":"0","ID":"sha256:dddd","Repository":"<none>","Tag":"<none>","SharedSize":"0B","Size":"631MB","UniqueSize":"631MB"},\
    {"Containers":"0","ID":"sha256:eeee","Repository":"redis","Tag":"8","SharedSize":"32B","Size":"160MB","UniqueSize":"159.9MB"},\
    {"ID":"sha256:ffff","Repository":"broken"}\
    ],"Containers":[],"Volumes":[],"BuildCache":[]}
    """

    func testParseImageIDsKeepsOnePerLine() {
        XCTAssertEqual(DockerSupport.parseImageIDs("sha256:aaaa\n\nsha256:bbbb\n"), ["sha256:aaaa", "sha256:bbbb"])
        XCTAssertEqual(DockerSupport.parseImageIDs(""), [])
        // A warning line printed on stdout is not an ID.
        XCTAssertEqual(DockerSupport.parseImageIDs("WARNING: something odd\nsha256:aaaa"), ["sha256:aaaa"])
    }

    func testDanglingLookupArgumentsUseTheFilterPruneUses() {
        XCTAssertEqual(DockerSupport.danglingImageIDsArguments,
                       ["images", "--filter", "dangling=true", "--no-trunc", "--format", "{{.ID}}"])
        XCTAssertEqual(DockerSupport.verboseSystemDFArguments, ["system", "df", "-v", "--format", "{{json .}}"])
    }

    func testParseImageUsageReadsIDsContainersAndUniqueSize() throws {
        let usage = try XCTUnwrap(DockerSupport.parseImageUsage(usageOutput))

        XCTAssertEqual(usage.first, .init(id: "sha256:aaaa", containers: 0, uniqueSize: 630_700_000))
        XCTAssertEqual(usage.map(\.id), ["sha256:aaaa", "sha256:bbbb", "sha256:dddd", "sha256:eeee"], "the entry without sizes is skipped")
        XCTAssertNil(DockerSupport.parseImageUsage("not json"))
        XCTAssertNil(DockerSupport.parseImageUsage("{\"Containers\":[]}"))
    }

    func testDanglingEstimateCountsUniqueSizeOfUnusedDanglingImagesOnly() throws {
        let usage = DockerSupport.parseImageUsage(usageOutput)
        // aaaa: unused. bbbb: a container uses it, so prune keeps it. cccc: not in df.
        // dddd is a digest-only <none>:<none> in df but NOT in the dangling list,
        // and eeee is tagged: neither may be counted.
        let estimate = try XCTUnwrap(DockerSupport.danglingEstimate(
            danglingIDs: ["sha256:aaaa", "sha256:bbbb", "sha256:cccc"],
            usage: usage
        ))

        XCTAssertEqual(estimate.count, 2)
        XCTAssertEqual(estimate.bytes, 630_700_000)
    }

    func testDanglingEstimateIsNilWhenNothingCanBePruned() {
        let usage = DockerSupport.parseImageUsage(usageOutput)
        XCTAssertNil(DockerSupport.danglingEstimate(danglingIDs: [], usage: usage))
        XCTAssertNil(DockerSupport.danglingEstimate(danglingIDs: nil, usage: usage), "unknown, so no row")
        XCTAssertNil(DockerSupport.danglingEstimate(danglingIDs: ["sha256:bbbb"], usage: usage), "the only image is in use")
    }

    func testDanglingEstimateHasNoSizeWhenVerboseDFIsUnavailable() {
        let estimate = DockerSupport.danglingEstimate(danglingIDs: ["sha256:aaaa", "sha256:bbbb"], usage: nil)
        XCTAssertEqual(estimate, .init(count: 2, bytes: nil))
    }

    func testPruneEstimatesMakeTheTwoImageRowsDisjoint() throws {
        let rows = DockerSupport.parseSystemDF(systemDFOutput)
        let estimates = DockerSupport.pruneEstimates(rows, dangling: .init(count: 1, bytes: 630_700_000))

        XCTAssertEqual(estimates.map { $0.action }, [.buildCache, .stoppedContainers, .danglingImages, .unusedImages, .unusedVolumes])
        let dangling = try XCTUnwrap(estimates.first { $0.action == .danglingImages })
        let all = try XCTUnwrap(estimates.first { $0.action == .unusedImages })
        XCTAssertEqual(dangling.bytes, 630_700_000)
        XCTAssertTrue(dangling.sizeKnown)
        // Selecting both rows must not promise more than df's single figure.
        XCTAssertEqual(dangling.bytes + all.bytes, 10_680_000_000)
    }

    func testDanglingRowWithoutAFigureIsLabelledUnknownAndKeepsTheImagesRow() throws {
        let rows = DockerSupport.parseSystemDF(systemDFOutput)
        for dangling in [DockerSupport.DanglingEstimate(count: 3, bytes: nil), .init(count: 3, bytes: 0)] {
            let estimates = DockerSupport.pruneEstimates(rows, dangling: dangling)
            let row = try XCTUnwrap(estimates.first { $0.action == .danglingImages })
            XCTAssertEqual(row.bytes, 0)
            XCTAssertFalse(row.sizeKnown)
            XCTAssertEqual(estimates.first { $0.action == .unusedImages }?.bytes, 10_680_000_000)
        }
    }

    func testImagesRowNeverGoesNegative() {
        let rows: [DockerSupport.DiskUsageRow] = [.init(type: "Images", size: 5_000, reclaimable: 1_000)]
        let estimates = DockerSupport.pruneEstimates(rows, dangling: .init(count: 1, bytes: 4_000))

        XCTAssertEqual(estimates.map { $0.action }, [.danglingImages])
    }

    // MARK: - ordering and freed space

    private func item(_ action: DockerSupport.PruneAction) -> CleanableItem {
        CleanableItem(name: action.rawValue, path: DockerSupport.actionPath(for: action), size: 1, category: .dockerCache, isSelected: true, lastModified: nil)
    }

    func testCleanOrderRunsContainersThenDanglingThenAllImagesThenVolumesThenBuildCache() {
        let sorted = DockerSupport.PruneAction.allCases.sorted { $0.cleanOrder < $1.cleanOrder }
        XCTAssertEqual(sorted, [.stoppedContainers, .danglingImages, .unusedImages, .unusedVolumes, .buildCache])
        XCTAssertEqual(Set(DockerSupport.PruneAction.allCases.map(\.cleanOrder)).count, DockerSupport.PruneAction.allCases.count)
    }

    func testOrderedForCleaningOnlyMovesDockerRowsWithinTheirOwnSlots() {
        let other = CleanableItem(name: "Logs", path: "/tmp/logs", size: 1, category: .userCache, isSelected: true, lastModified: nil)
        let items = [item(.buildCache), other, item(.unusedImages), item(.danglingImages)]

        let ordered = DockerSupport.orderedForCleaning(items)

        XCTAssertEqual(ordered.map(\.name), ["dangling-images", "Logs", "images", "build-cache"])
    }

    /// A shell script standing in for docker: it appends its arguments to a
    /// log and prints what each real prune prints. No real docker is run.
    private func makeFakeDocker() throws -> (dir: URL, binary: String, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PureMac-FakeDocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        let script = """
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        case "$*" in
        "container prune -f") printf 'Deleted Containers:\\nabc\\n\\nTotal reclaimed space: 20.19MB\\n' ;;
        "image prune -f") printf 'Deleted Images:\\ndeleted: sha256:aaaa\\n\\nTotal reclaimed space: 630MB\\n' ;;
        "image prune -a -f") printf 'Deleted Images:\\ndeleted: sha256:eeee\\n\\nTotal reclaimed space: 9.4GB\\n' ;;
        "volume prune -a -f") printf 'Total reclaimed space: 5.55GB\\n' ;;
        "builder prune -a -f") printf 'ID\\tRECLAIMABLE\\tSIZE\\nTotal:\\t1.5GB\\n' ;;
        *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """
        let binary = dir.appendingPathComponent("docker")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (dir, binary.path, log)
    }

    func testCleanRunsSelectedPrunesInOrderAndSumsFreedSpaceWithoutOverlap() async throws {
        let fake = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        // Selected in the "wrong" order on purpose.
        let selected = [item(.buildCache), item(.unusedImages), item(.danglingImages), item(.stoppedContainers)]

        let result = await engine.cleanItems(selected) { _ in }

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["container prune -f", "image prune -f", "image prune -a -f", "builder prune -a -f"])
        // Each command reports only what it removed itself, so the sum is
        // exact: 20.19MB + 630MB + 9.4GB + 1.5GB.
        XCTAssertEqual(result.freedSpace, 20_190_000 + 630_000_000 + 9_400_000_000 + 1_500_000_000)
        XCTAssertEqual(result.itemsCleaned, 4)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
    }

    func testCleanWithOnlyDanglingNeverRunsTheAllImagesPrune() async throws {
        let fake = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let result = await engine.cleanItems([item(.danglingImages)]) { _ in }

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["image prune -f"])
        XCTAssertEqual(result.freedSpace, 630_000_000)
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

    func testRisksMatchTheSelectedRowsExactly() {
        func risks(_ actions: [DockerSupport.PruneAction]) -> [String] {
            RemovalRisk.risks(for: .dockerCache, items: actions.map { prune($0, selected: true) })
        }
        // The Trash line is always there; every kind of row adds its own risk.
        XCTAssertEqual(risks([.buildCache]).count, 2)
        XCTAssertEqual(risks([.stoppedContainers]).count, 2)
        XCTAssertEqual(risks([.danglingImages]).count, 2)
        XCTAssertEqual(risks([.unusedImages]).count, 2)
        XCTAssertEqual(risks([.buildCache, .stoppedContainers, .danglingImages]).count, 4)
        // `image prune -a` already covers dangling images: one image risk, not two.
        XCTAssertEqual(risks([.danglingImages, .unusedImages]).count, 2)
        XCTAssertEqual(risks([.buildCache, .stoppedContainers, .unusedImages]).count, 4)
        // The volumes risk appears only with the volumes row.
        XCTAssertEqual(risks([.buildCache, .unusedVolumes]).count, 3)
        XCTAssertEqual(risks(DockerSupport.PruneAction.allCases).count, 5)
        XCTAssertTrue(RemovalRisk.risks(for: .userCache, items: [prune(.buildCache, selected: true)]).isEmpty)
        XCTAssertFalse(RemovalRisk.requiresAcknowledgement(.userCache))
    }

    func testRiskTextsNameWhatTheCommandRemoves() {
        func joined(_ actions: [DockerSupport.PruneAction]) -> String {
            RemovalRisk.risks(for: .dockerCache, items: actions.map { prune($0, selected: true) }).joined(separator: "\n")
        }
        let dangling = joined([.danglingImages])
        XCTAssertTrue(dangling.contains("Dangling images (no tag)"))
        XCTAssertFalse(dangling.contains("tagged or not"), "dangling-only must not warn about tagged images")

        let all = joined([.unusedImages])
        XCTAssertTrue(all.contains("tagged or not"))
        XCTAssertTrue(all.contains("built locally and never pushed"))
        XCTAssertFalse(all.contains("erased"), "no volumes risk without the volumes row")

        XCTAssertTrue(joined([.unusedVolumes]).contains("erased with their data"))
        XCTAssertFalse(joined([.buildCache]).contains("Stopped containers"))
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
        XCTAssertTrue(prompt.contains("docker images --filter dangling=true"))
    }
}
