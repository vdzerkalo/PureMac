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

    // MARK: - prune estimate

    func testSystemPruneEstimateExcludesImagesAndVolumes() {
        // `docker system prune -f` keeps tagged images and every volume, so
        // only the container and build-cache figures may be promised.
        let estimate = DockerSupport.systemPruneEstimate(DockerSupport.parseSystemDF(systemDFOutput))

        XCTAssertEqual(estimate, 20_190_000 + 11_290_000_000)
    }

    func testSystemPruneEstimateOfNoRowsIsZero() {
        XCTAssertEqual(DockerSupport.systemPruneEstimate([]), 0)
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
