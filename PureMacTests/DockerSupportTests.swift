import XCTest
@testable import PureMac

/// How the fake `docker builder prune -a -f` behaves.
enum FakeBuilder {
    case normal
    case failsWith(String)
    case hangs
}

/// A shell script standing in for docker: it appends its arguments to a log
/// and prints what each real command prints. `volume prune` is deliberately
/// absent (it answers "unexpected" and fails) because PureMac must never run
/// it. The real docker binary is never run by any test.
func makeFakeDockerCLI(
    unusedVolumes: [String],
    inUseVolumes: [String],
    builder: FakeBuilder,
    hugeImageOutput: Bool,
    vanishedVolumes: [String] = []
) throws -> (dir: URL, binary: String, log: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PureMac-FakeDocker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("calls.log")
    let unusedList = unusedVolumes.map { "'\($0)'" }.joined(separator: " ")
    let inUse = " " + inUseVolumes.joined(separator: " ") + " "
    let vanished = " " + vanishedVolumes.joined(separator: " ") + " "
    let builderBranch: String
    switch builder {
    case .normal: builderBranch = "printf 'ID\\tRECLAIMABLE\\tSIZE\\nTotal:\\t1.5GB\\n'"
    case .failsWith(let message): builderBranch = "echo '\(message)' >&2; exit 1"
    case .hangs: builderBranch = "exec sleep 30"
    }
    let imageAll = hugeImageOutput
        ? "awk 'BEGIN{for(i=0;i<300000;i++) print \"deleted: sha256:\" i; print \"Total reclaimed space: 1.5GB\"}'"
        : "printf 'Deleted Images:\\ndeleted: sha256:eeee\\n\\nTotal reclaimed space: 9.4GB\\n'"
    let script = """
    #!/bin/sh
    echo "$*" >> "\(log.path)"
    case "$*" in
    "container prune -f") printf 'Deleted Containers:\\nabc\\n\\nTotal reclaimed space: 20.19MB\\n' ;;
    "image prune -f") printf 'Deleted Images:\\ndeleted: sha256:aaaa\\n\\nTotal reclaimed space: 630MB\\n' ;;
    "image prune -a -f") \(imageAll) ;;
    "builder prune -a -f") \(builderBranch) ;;
    "volume ls -q --filter dangling=true") printf '%s\\n' \(unusedList) ;;
    "volume rm "*)
      shift 2
      fail=0
      for n in "$@"; do
        case "\(inUse)" in
          *" $n "*) echo "Error response from daemon: remove $n: volume is in use - [abc]" >&2; fail=1 ;;
          *) case "\(vanished)" in
               *" $n "*) echo "Error response from daemon: get $n: no such volume" >&2; fail=1 ;;
               *) echo "$n" ;;
             esac ;;
        esac
      done
      exit $fail ;;
    *) echo "unexpected: $*" >&2; exit 1 ;;
    esac
    """
    let binary = dir.appendingPathComponent("docker")
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return (dir, binary.path, log)
}

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
        // The volumes row is not df's "Local Volumes" figure: it is the sum of
        // the recorded unused volumes (here 2 GB + 3.55 GB).
        let volumes = DockerSupport.VolumeEstimate(entries: [
            .init(name: "pgdata", bytes: 2_000_000_000), .init(name: "uploads", bytes: 3_550_000_000),
        ])
        let estimates = DockerSupport.pruneEstimates(DockerSupport.parseSystemDF(systemDFOutput), volumes: volumes)

        XCTAssertEqual(estimates.map { $0.action }, [.buildCache, .stoppedContainers, .unusedImages, .unusedVolumes])
        XCTAssertEqual(estimates.map { $0.bytes }, [11_290_000_000, 20_190_000, 10_680_000_000, 5_550_000_000])
        XCTAssertTrue(estimates.allSatisfy { $0.sizeKnown })
        XCTAssertEqual(estimates.last?.volumes.map(\.name), ["pgdata", "uploads"])
        // Without a recorded volume list there is no volumes row, whatever df says.
        XCTAssertFalse(DockerSupport.pruneEstimates(DockerSupport.parseSystemDF(systemDFOutput)).contains { $0.action == .unusedVolumes })
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
        // Volumes are never pruned: only `volume rm <recorded names>`, without -f.
        XCTAssertEqual(DockerSupport.PruneAction.unusedVolumes.arguments, ["volume", "rm"])
        XCTAssertFalse(DockerSupport.PruneAction.unusedVolumes.arguments.contains("-f"))
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

        XCTAssertEqual(estimates.map { $0.action }, [.buildCache, .stoppedContainers, .danglingImages, .unusedImages])
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

    private func item(_ action: DockerSupport.PruneAction, volumes: [DockerSupport.VolumeEntry] = []) -> CleanableItem {
        CleanableItem(name: action.rawValue, path: DockerSupport.actionPath(for: action, volumes: volumes), size: 1, category: .dockerCache, isSelected: true, lastModified: nil)
    }

    func testCleanOrderRunsVolumesBeforeContainersThenDanglingThenAllImagesThenBuildCache() {
        let sorted = DockerSupport.PruneAction.allCases.sorted { $0.cleanOrder < $1.cleanOrder }
        XCTAssertEqual(sorted, [.unusedVolumes, .stoppedContainers, .danglingImages, .unusedImages, .buildCache])
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
    private func makeFakeDocker(
        unusedVolumes: [String] = [],
        inUseVolumes: [String] = [],
        builder: FakeBuilder = .normal,
        hugeImageOutput: Bool = false,
        vanishedVolumes: [String] = []
    ) throws -> (dir: URL, binary: String, log: URL) {
        try makeFakeDockerCLI(unusedVolumes: unusedVolumes, inUseVolumes: inUseVolumes, builder: builder, hugeImageOutput: hugeImageOutput, vanishedVolumes: vanishedVolumes)
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

    func testRunningDaemonErrorsAreNotReportedAsDockerNotRunning() {
        // Regression: any text containing "daemon" used to read as "not running".
        XCTAssertFalse(DockerSupport.isDaemonUnavailable(
            stderr: "Error response from daemon: a prune operation is already running"
        ))
        XCTAssertFalse(DockerSupport.isDaemonUnavailable(
            stderr: "Error response from daemon: remove pgdata: volume is in use - [abc]"
        ))
    }

    func testDescribeUsesDockerWordingNotHomebrewWording() {
        XCTAssertEqual(DockerSupport.describe(ApplicationUpdaterError.timedOut, timeout: 10), "timed out after 10s")
        XCTAssertEqual(DockerSupport.describe(ApplicationUpdaterError.outputLimitExceeded, timeout: 10),
                       "printed more output than PureMac can read")
        XCTAssertFalse(DockerSupport.describe(ApplicationUpdaterError.timedOut, timeout: 10).contains("Homebrew"))
    }

    // MARK: - unused volumes (recorded names, volume rm)

    func testVolumeNamesAreValidatedSoTheyCannotBecomeOptionsOrPaths() {
        for good in ["pgdata", "my_vol-1.x", "0abc", String(repeating: "a", count: 64)] {
            XCTAssertTrue(DockerSupport.isValidVolumeName(good), good)
        }
        for bad in ["", "-f", "--all", "a b", "../x", "a/b", "a=b", "a,b", "a:b", "_x", ".x", "é"] {
            XCTAssertFalse(DockerSupport.isValidVolumeName(bad), bad)
        }
        XCTAssertEqual(DockerSupport.parseVolumeNames("pgdata\n--all\n\nuploads\na b\n"), ["pgdata", "uploads"])
    }

    func testVolumesRowPathRoundTripsAndDropsInvalidNames() {
        let entries: [DockerSupport.VolumeEntry] = [.init(name: "pgdata", bytes: 5_000_000_000), .init(name: "up.loads", bytes: 0)]
        let path = DockerSupport.actionPath(for: .unusedVolumes, volumes: entries + [.init(name: "--all", bytes: 1)])

        XCTAssertEqual(path, "docker-prune:volumes:pgdata=5000000000,up.loads=0")
        XCTAssertEqual(DockerSupport.action(forPath: path), .unusedVolumes)
        XCTAssertEqual(DockerSupport.volumeEntries(forPath: path), entries)
        XCTAssertEqual(DockerSupport.arguments(forPath: path), ["volume", "rm", "pgdata", "up.loads"])
        XCTAssertEqual(DockerSupport.commandLine(forPath: path), "docker volume rm pgdata up.loads")
        // A tampered path cannot smuggle an option.
        XCTAssertEqual(DockerSupport.volumeEntries(forPath: "docker-prune:volumes:--all=1,ok=2"), [.init(name: "ok", bytes: 2)])
        // A volumes row with no names never becomes a bare `volume rm`.
        XCTAssertNil(DockerSupport.arguments(forPath: DockerSupport.actionPath(for: .unusedVolumes)))
        XCTAssertNil(DockerSupport.arguments(forPath: "docker-prune:volumes:--all=1"))
        XCTAssertEqual(DockerSupport.arguments(forPath: "docker-prune:images"), ["image", "prune", "-a", "-f"])
        XCTAssertNil(DockerSupport.arguments(forPath: "/tmp/x"))
    }

    func testVolumeEstimateUsesOnlyTheRecordedUnusedVolumesAndTheirOwnSizes() throws {
        let verbose = """
        {"Images":[],"Volumes":[\
        {"Name":"pgdata","Links":"0","Size":"5.55GB"},\
        {"Name":"cache","Links":"0","Size":"N/A"},\
        {"Name":"busy","Links":"1","Size":"2GB"},\
        {"Name":"stopped-db","Links":"1","Size":"5GB"}\
        ],"Containers":[],"BuildCache":[]}
        """
        let usage = try XCTUnwrap(DockerSupport.parseVolumeUsage(verbose))
        XCTAssertEqual(usage.first, .init(name: "pgdata", links: 0, size: 5_550_000_000))
        XCTAssertNil(usage[1].size)

        // "stopped-db" is held by a stopped container, so it is not in the
        // unused list and its 5 GB can never appear in the row. "busy" was
        // listed but df says a container uses it: dropped.
        let estimate = try XCTUnwrap(DockerSupport.volumeEstimate(names: ["pgdata", "cache", "busy", "pgdata", "-x"], usage: usage))
        XCTAssertEqual(estimate.entries, [.init(name: "pgdata", bytes: 5_550_000_000), .init(name: "cache", bytes: 0)])
        XCTAssertEqual(estimate.bytes, 5_550_000_000)

        // df -v unavailable: names are known, sizes are not.
        XCTAssertEqual(DockerSupport.volumeEstimate(names: ["pgdata"], usage: nil)?.bytes, 0)
        XCTAssertNil(DockerSupport.volumeEstimate(names: [], usage: usage))
        XCTAssertNil(DockerSupport.volumeEstimate(names: nil, usage: usage))
        XCTAssertNil(DockerSupport.volumeEstimate(names: ["busy"], usage: usage))

        let rows = DockerSupport.pruneEstimates([], volumes: DockerSupport.volumeEstimate(names: ["cache"], usage: usage))
        XCTAssertEqual(rows.map(\.action), [.unusedVolumes])
        XCTAssertFalse(rows[0].sizeKnown, "a 0 size is labelled 'not estimated'")
    }

    func testParseVolumeRemovalSeparatesRemovedFromFailuresAndIgnoresVanishedVolumes() {
        let requested: [DockerSupport.VolumeEntry] = [.init(name: "a", bytes: 10), .init(name: "b", bytes: 20), .init(name: "c", bytes: 30)]
        let outcome = DockerSupport.parseVolumeRemoval(
            stdout: "a\n",
            stderr: """
            Error response from daemon: remove b: volume is in use - [abc]
            Error response from daemon: get c: no such volume
            """,
            requested: requested
        )

        XCTAssertEqual(outcome.removed, [.init(name: "a", bytes: 10)])
        XCTAssertEqual(outcome.problems, ["docker volume rm: remove b: volume is in use - [abc]"], "a vanished volume is silent")
    }

    func testVolumeRemovalNeverTouchesVolumesFreedByTheContainerPrune() async throws {
        // Regression (HIGH): a 5 GB volume held by a stopped container is not
        // "unused" at scan time. Selecting containers + volumes used to run
        // `volume prune -a -f` after the container prune and erase it.
        let fake = try makeFakeDocker(unusedVolumes: ["scratch"])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let volumes = item(.unusedVolumes, volumes: [.init(name: "scratch", bytes: 200_000_000)])

        let result = await engine.cleanItems([item(.stoppedContainers), volumes]) { _ in }

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["volume ls -q --filter dangling=true", "volume rm scratch", "container prune -f"])
        XCTAssertFalse(calls.contains { $0.contains("volume prune") })
        XCTAssertFalse(calls.contains { $0.hasPrefix("volume rm") && ($0.contains(" -f") || $0.contains("--force")) })
        XCTAssertEqual(result.freedSpace, 200_000_000 + 20_190_000)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.itemsCleaned, 2)
    }

    func testRecordedVolumeThatVanishedOrBecameUsedIsSkippedSilently() async throws {
        // Only "kept" is still unused; "gone" no longer exists; "now-used" was
        // unused at scan time but a container holds it now.
        let fake = try makeFakeDocker(unusedVolumes: ["kept"])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let row = item(.unusedVolumes, volumes: [.init(name: "gone", bytes: 1), .init(name: "now-used", bytes: 2), .init(name: "kept", bytes: 3)])

        let result = await engine.cleanItems([row]) { _ in }

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["volume ls -q --filter dangling=true", "volume rm kept"])
        XCTAssertEqual(result.freedSpace, 3)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
    }

    func testNothingLeftToRemoveRunsNoRemoval() async throws {
        let fake = try makeFakeDocker(unusedVolumes: [])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let result = await engine.cleanItems([item(.unusedVolumes, volumes: [.init(name: "gone", bytes: 9)])]) { _ in }

        let calls = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["volume ls -q --filter dangling=true"])
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
    }

    func testVolumeInUseAfterTheRecheckIsReportedPerVolumeAndTheRestStillGo() async throws {
        let fake = try makeFakeDocker(unusedVolumes: ["a", "b"], inUseVolumes: ["b"])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let row = item(.unusedVolumes, volumes: [.init(name: "a", bytes: 10), .init(name: "b", bytes: 20)])

        let result = await engine.cleanItems([row]) { _ in }

        XCTAssertEqual(result.freedSpace, 10)
        XCTAssertEqual(result.errors, ["docker volume rm: remove b: volume is in use - [abc]"])
        XCTAssertEqual(result.itemsCleaned, 0, "a row with a failed volume is not marked cleaned")
    }

    func testVolumeThatVanishesBetweenTheRecheckAndTheRemovalIsAQuietSkip() async throws {
        // "ghost" is still listed by the re-check, then gone when rm runs:
        // docker answers "no such volume" and exits 1. Not an error.
        let fake = try makeFakeDocker(unusedVolumes: ["ghost"], vanishedVolumes: ["ghost"])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let result = await engine.cleanItems([item(.unusedVolumes, volumes: [.init(name: "ghost", bytes: 7)])]) { _ in }

        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertEqual(result.itemsCleaned, 1)
    }

    func testVanishedVolumeDoesNotHideOtherRemovalErrors() async throws {
        let fake = try makeFakeDocker(unusedVolumes: ["a", "b", "ghost"], inUseVolumes: ["b"], vanishedVolumes: ["ghost"])
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let row = item(.unusedVolumes, volumes: [.init(name: "a", bytes: 10), .init(name: "b", bytes: 20), .init(name: "ghost", bytes: 30)])

        let result = await engine.cleanItems([row]) { _ in }

        XCTAssertEqual(result.freedSpace, 10)
        XCTAssertEqual(result.errors, ["docker volume rm: remove b: volume is in use - [abc]"])
    }

    func testNoSuchVolumeForAnUnrequestedNameIsStillReported() {
        let outcome = DockerSupport.parseVolumeRemoval(
            stdout: "",
            stderr: "Error response from daemon: get other: no such volume",
            requested: [.init(name: "a", bytes: 1)]
        )
        XCTAssertEqual(outcome.vanished, 0)
        XCTAssertEqual(outcome.problems, ["docker volume rm: get other: no such volume"])
    }

    // MARK: - cancellation, daemon errors, long output

    func testCancelledPruneIsAnErrorNotACleanedRow() async throws {
        let fake = try makeFakeDocker(builder: .hangs)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let task = Task { await engine.cleanItems([item(.buildCache)]) { _ in } }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.cleanedPaths.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("was cancelled"), "\(result.errors)")
    }

    func testRunningDaemonErrorKeepsDockerErrorTextAndIsNotMappedToNotRunning() async throws {
        let fake = try makeFakeDocker(builder: .failsWith("Error response from daemon: a prune operation is already running"))
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let outcome = await engine.pruneDocker(.buildCache)

        XCTAssertEqual(outcome.freed, 0)
        XCTAssertEqual(outcome.error, "docker builder prune -a -f failed (exit 1)")
    }

    func testRealConnectionErrorStillReadsAsDockerNotRunning() async throws {
        let fake = try makeFakeDocker(builder: .failsWith("Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?"))
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let outcome = await engine.pruneDocker(.buildCache)

        XCTAssertEqual(outcome.error, "Docker isn't running — start Docker Desktop or OrbStack, then clean again")
    }

    func testLongPruneOutputStillYieldsTheSummary() async throws {
        // ~7 MB of "deleted:" lines, then the summary: over the 4 MB cap that
        // kills brew-style runs, but a prune keeps only the tail.
        let fake = try makeFakeDocker(hugeImageOutput: true)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)

        let outcome = await engine.pruneDocker(.unusedImages)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.freed, 1_500_000_000)
    }

    func testDefaultRunnerStillFailsPastTheOutputCapAndTailModeDoesNot() async throws {
        let awk = URL(fileURLWithPath: "/usr/bin/awk")
        let program = "BEGIN{for(i=0;i<300000;i++) print \"line number \" i; print \"Total: 1B\"}"
        do {
            _ = try await BrewProcessRunner.run(executableURL: awk, arguments: [program], timeout: 20)
            XCTFail("Homebrew behaviour must keep failing past the output cap")
        } catch {
            XCTAssertEqual(error as? ApplicationUpdaterError, .outputLimitExceeded)
        }
        let tail = try await BrewProcessRunner.run(executableURL: awk, arguments: [program], timeout: 20, keepOutputTail: true)
        XCTAssertEqual(tail.status, 0)
        XCTAssertLessThanOrEqual(tail.stdout.count, BrewProcessRunner.tailWindowBytes)
        XCTAssertTrue(String(decoding: tail.stdout, as: UTF8.self).hasSuffix("Total: 1B\n"))
    }

    // MARK: - Docker disks are never unlinked

    private func protectedFixture() throws -> (engine: CleaningEngine, home: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PureMac-ProtectedHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let engine = CleaningEngine(homeDirectory: dir)
        return (engine, dir.resolvingSymlinksInPath().path)
    }

    func testDockerAndOrbStackDisksAreRefusedInUserAndAdminPass() async throws {
        let (engine, home) = try protectedFixture()
        let refused = [
            "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "\(home)/Library/Containers/com.docker.docker/Data/vms",
            "\(home)/Library/Containers/com.docker.docker/Data",
            "\(home)/Library/Containers/com.docker.docker",
            "\(home)/Library/Containers/COM.DOCKER.DOCKER/data/VMS/0/data/docker.raw",
            "\(home)/Library/Group Containers/group.com.docker/settings.json",
            "\(home)/Library/Group Containers/group.com.docker",
            "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img",
            "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack",
            "\(home)/.orbstack/data/data.img",
            "\(home)/.orbstack",
            "\(home)/.docker/desktop/vms",
        ]
        for path in refused {
            for category in [CleaningCategory.dockerCache, .userCache] {
                let item = CleanableItem(name: "disk", path: path, size: 1, category: category, isSelected: true, lastModified: nil)
                let user = await engine.isSafeToDelete(item: item, resolvedPath: path)
                let admin = await engine.isSafeToDelete(item: item, resolvedPath: path, includeUninstallPaths: true)
                XCTAssertFalse(user, "user pass must refuse \(path)")
                XCTAssertFalse(admin, "admin pass must refuse \(path)")
            }
        }
    }

    func testParentsOfProtectedDisksAreRefusedToo() async throws {
        // ~/Library/Containers and ~/Library/Group Containers are whole-folder
        // allow-list roots, so an item equal to one of them, or to any folder
        // that contains a protected disk, must be refused.
        let (engine, home) = try protectedFixture()
        let parents = [
            home,
            "\(home)/Library",
            "\(home)/Library/Containers",
            "\(home)/Library/Containers/",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Group Containers/",
            "\(home)/Library/Containers/com.docker.docker",
            "\(home)/Library/Containers/com.docker.docker/Data",
            "\(home)/Library/Containers/com.docker.docker/Data/vms/0",
            "\(home)/Library/Group Containers/group.com.docker",
            "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack",
            "\(home)/.orbstack",
            "\(home)/.docker",
            // case variants
            "\(home)/LIBRARY/containers",
            "\(home)/library/GROUP containers",
            "\(home)/.ORBSTACK",
            "\(home)/Library/Containers/Com.Docker.Docker/DATA",
        ]
        for path in parents {
            let item = CleanableItem(name: "parent", path: path, size: 1, category: .userCache, isSelected: true, lastModified: nil)
            let user = await engine.isSafeToDelete(item: item, resolvedPath: path)
            let admin = await engine.isSafeToDelete(item: item, resolvedPath: path, includeUninstallPaths: true)
            XCTAssertFalse(user, "user pass must refuse \(path)")
            XCTAssertFalse(admin, "admin pass must refuse \(path)")
        }
    }

    func testDotDotAndTrailingSlashSpellingsOfDiskPathsAreRefused() async throws {
        let (engine, home) = try protectedFixture()
        let tricky = [
            "\(home)/Library/Containers/com.docker.docker/Data/cache/../vms/0/data/Docker.raw",
            "\(home)/Library/Caches/../Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "\(home)/Library/Containers/com.docker.docker/Data/vms/",
            "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw/",
            "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/../data/data.img",
            "\(home)/Library/Containers/com.docker.docker/Data/cache/../../",
        ]
        for path in tricky {
            for category in [CleaningCategory.dockerCache, .userCache] {
                let item = CleanableItem(name: "disk", path: path, size: 1, category: category, isSelected: true, lastModified: nil)
                // Once with the spelling as given, once as the engine would resolve it.
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                for candidate in [path, resolved] {
                    let user = await engine.isSafeToDelete(item: item, resolvedPath: candidate)
                    let admin = await engine.isSafeToDelete(item: item, resolvedPath: candidate, includeUninstallPaths: true)
                    XCTAssertFalse(user, "user pass must refuse \(path) as \(candidate)")
                    XCTAssertFalse(admin, "admin pass must refuse \(path) as \(candidate)")
                }
            }
        }
    }

    func testSymlinkedParentIntoADiskFolderIsRefused() async throws {
        let (engine, home) = try protectedFixture()
        let vms = "\(home)/Library/Containers/com.docker.docker/Data/vms"
        let raw = "\(vms)/0/data/Docker.raw"
        try FileManager.default.createDirectory(atPath: (raw as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: raw, contents: Data("x".utf8)))
        // An innocent-looking folder in an allowed root that points at the disks.
        try FileManager.default.createDirectory(atPath: "\(home)/Library/Caches", withIntermediateDirectories: true)
        let alias = "\(home)/Library/Caches/looks-harmless"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: vms)

        for path in [alias, "\(alias)/0/data/Docker.raw"] {
            // The engine passes the unresolved item path and the resolved one;
            // the check must hold for the symlink spelling alone as well.
            let item = CleanableItem(name: "alias", path: path, size: 1, category: .userCache, isSelected: true, lastModified: nil)
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            for candidate in [path, resolved] {
                let user = await engine.isSafeToDelete(item: item, resolvedPath: candidate)
                let admin = await engine.isSafeToDelete(item: item, resolvedPath: candidate, includeUninstallPaths: true)
                XCTAssertFalse(user, "user pass must refuse \(path) as \(candidate)")
                XCTAssertFalse(admin, "admin pass must refuse \(path) as \(candidate)")
            }
        }
        let result = await engine.cleanItems([
            CleanableItem(name: "alias", path: "\(alias)/0/data/Docker.raw", size: 1, category: .userCache, isSelected: true, lastModified: nil),
        ]) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw))
        XCTAssertEqual(result.itemsCleaned, 0)
    }

    func testDockerCacheFoldersStayCleanable() async throws {
        let (engine, home) = try protectedFixture()
        let allowed = [
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            "\(home)/Library/Containers/com.docker.docker/Data/log/vm.log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            "\(home)/Library/Group Containers/group.com.docker/Caches/x",
            "\(home)/.orbstack/log",
        ]
        for path in allowed {
            let item = CleanableItem(name: "cache", path: path, size: 1, category: .dockerCache, isSelected: true, lastModified: nil)
            let accepted = await engine.isSafeToDelete(item: item, resolvedPath: path)
            XCTAssertTrue(accepted, "\(path) should stay cleanable")
        }
    }

    func testCleanItemsLeavesDockerRawOnDisk() async throws {
        let (engine, home) = try protectedFixture()
        let raw = URL(fileURLWithPath: "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: raw.path, contents: Data("x".utf8)))
        let item = CleanableItem(name: "Docker.raw", path: raw.path, size: 1, category: .dockerCache, isSelected: true, lastModified: nil)

        let result = await engine.cleanItems([item]) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.contains { $0.contains("unsafe path") }, "\(result.errors)")
    }
}

/// Overview "Clean" must not bypass the Docker risk review.
@MainActor
final class DockerOverviewTests: XCTestCase {
    func testCleanAllNeverRunsDockerPrunesWhateverIsSelected() async throws {
        let fake = try makeFakeDockerCLI(unusedVolumes: ["a"], inUseVolumes: [], builder: .normal, hugeImageOutput: false)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let state = AppState(performStartupTasks: false, cleaningEngine: engine)
        let items = DockerSupport.PruneAction.allCases.map { action in
            CleanableItem(
                name: action.rawValue,
                path: DockerSupport.actionPath(for: action, volumes: action == .unusedVolumes ? [.init(name: "a", bytes: 1)] : []),
                size: 100, category: .dockerCache, isSelected: true, lastModified: nil
            )
        }
        state.categoryResults[.dockerCache] = CategoryResult(category: .dockerCache, items: items, totalSize: 500)

        // Overview totals and selection exclude Docker.
        XCTAssertEqual(state.totalSelectedSize, 0)
        XCTAssertTrue(state.overviewSelectedItems.isEmpty)
        XCTAssertTrue(state.isReviewedInCategoryOnly(.dockerCache))
        XCTAssertFalse(state.isReviewedInCategoryOnly(.userCache))
        let binding = state.categoryBinding(for: .dockerCache)
        binding.wrappedValue = true
        XCTAssertFalse(binding.wrappedValue)

        state.cleanAll()
        state.cleanAll(itemIDs: Set(items.map(\.id)))
        state.cleanAll(scheduled: true)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.log.path), "no docker command may run from the Overview")
        XCTAssertEqual(state.scanState, .idle)
    }

    func testFullDiskAccessRetryDoesNotRunDockerPrunes() async throws {
        let fake = try makeFakeDockerCLI(unusedVolumes: ["a"], inUseVolumes: [], builder: .normal, hugeImageOutput: false)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let engine = CleaningEngine(homeDirectory: fake.dir, dockerBinaryPath: fake.binary)
        let state = AppState(performStartupTasks: false, cleaningEngine: engine)
        let items = DockerSupport.PruneAction.allCases.map { action in
            CleanableItem(
                name: action.rawValue,
                path: DockerSupport.actionPath(for: action, volumes: action == .unusedVolumes ? [.init(name: "a", bytes: 1)] : []),
                size: 100, category: .dockerCache, isSelected: true, lastModified: nil
            )
        }

        await state.retryAfterFullDiskAccess(items: items, context: .cleanup(failedCount: items.count))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.log.path), "a permission retry must not bypass the Docker review")
        XCTAssertEqual(state.scanState, .idle)
    }
}

final class RemovalRiskTests: XCTestCase {
    private func prune(_ action: DockerSupport.PruneAction, selected: Bool, volumes: [DockerSupport.VolumeEntry] = []) -> CleanableItem {
        CleanableItem(name: action.diskUsageType, path: DockerSupport.actionPath(for: action, volumes: volumes), size: 4_096, category: .dockerCache, isSelected: selected, lastModified: nil)
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
        let volumes = prune(.unusedVolumes, selected: false, volumes: [.init(name: "pgdata", bytes: 5)])
        let prompt = RemovalRisk.agentPrompt(category: .dockerCache, found: [cache, volumes], proposed: [cache.id])
        let rows = prompt.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| #") }

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].contains("| ✔ |") && rows[0].contains("`docker builder prune -a -f`"), String(rows[0]))
        XCTAssertTrue(rows[1].contains("| · |") && rows[1].contains("`docker volume rm pgdata`") && rows[1].contains("erases data"), String(rows[1]))
        XCTAssertTrue(prompt.contains("Read-only: do not delete"))
        XCTAssertTrue(prompt.contains("No sub-agents"))
        XCTAssertTrue(prompt.contains("Proposed: 1 of 2 items"))
        XCTAssertTrue(prompt.contains("docker images --filter dangling=true"))
    }
}
