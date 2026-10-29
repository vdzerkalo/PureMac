import XCTest
@testable import PureMac

/// Local AI Models: Ollama listing/removal and the Hugging Face caches.
///
/// Nothing here starts a real `ollama` or `hf` or opens a socket. Tools are
/// fake shell scripts in a temp folder that log the arguments they receive;
/// the HTTP layer is a stub; model stores are fixture trees under `$TMPDIR`.
final class LocalAIModelsTests: XCTestCase {
    private typealias Support = LocalAIModelsSupport

    private let fileManager = FileManager.default
    private var sandbox: URL!
    private var home: URL!
    private var tools: URL!
    private var logFile: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PureMac-LocalAI-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: try XCTUnwrap(Support.canonicalPath(base.path)), isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        tools = sandbox.appendingPathComponent("tools", isDirectory: true)
        logFile = tools.appendingPathComponent("invocations.log")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: tools, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox, fileManager.fileExists(atPath: sandbox.path) {
            try fileManager.removeItem(at: sandbox)
        }
    }

    // MARK: - Categories

    func testLocalAIModelsAreScannableButNeverPartOfSmartScanOrSchedules() {
        XCTAssertTrue(CleaningCategory.scannable.contains(.localAIModels))
        XCTAssertFalse(CleaningCategory.smartScannable.contains(.localAIModels))
        XCTAssertFalse(ScheduleConfig().categoriesToScan.contains(.localAIModels))
        XCTAssertTrue(CleaningCategory.userDataCategories.contains(.localAIModels))
        // Every other category keeps taking part in Smart Scan.
        XCTAssertEqual(
            Set(CleaningCategory.smartScannable),
            Set(CleaningCategory.scannable).subtracting([.localAIModels])
        )
    }

    @MainActor
    func testBulkCleaningResultsExcludeLocalAIModelsEvenWhenSelected() {
        let state = AppState(performStartupTasks: false)
        let item = CleanableItem(
            name: "qwen3.5:9b",
            path: CleanableItem.ollamaModelPathPrefix + "qwen3.5:9b",
            size: 6_600_000_000,
            category: .localAIModels,
            isSelected: false,
            lastModified: nil
        )
        state.categoryResults[.localAIModels] = CategoryResult(
            category: .localAIModels, items: [item], totalSize: item.size
        )
        state.toggleItem(item)

        XCTAssertTrue(state.isItemSelected(item))
        XCTAssertTrue(state.allResults.isEmpty, "cleanAll and scheduled cleaning read allResults")
        XCTAssertEqual(state.totalSelectedSize, 0)
    }

    func testOllamaRowsAreActionItemsWithTheModelName() {
        let item = CleanableItem(
            name: "x", path: CleanableItem.ollamaModelPathPrefix + "hf.co/org/repo:Q4_K_M",
            size: 1, category: .localAIModels, isSelected: false, lastModified: nil
        )
        XCTAssertTrue(item.isActionItem)
        XCTAssertEqual(item.ollamaModelName, "hf.co/org/repo:Q4_K_M")
        let other = CleanableItem(
            name: "x", path: CleanableItem.ollamaModelPathPrefix + "a",
            size: 1, category: .aiApps, isSelected: false, lastModified: nil
        )
        XCTAssertNil(other.ollamaModelName, "only Local AI Models rows can request ollama rm")
    }

    // MARK: - Parsing

    func testOllamaEndpointParsing() throws {
        func endpoint(_ host: String?) -> Support.OllamaEndpoint? {
            Support.ollamaEndpoint(environment: host.map { ["OLLAMA_HOST": $0] } ?? [:])
        }
        XCTAssertEqual(endpoint(nil)?.baseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(endpoint("")?.baseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(endpoint("0.0.0.0")?.baseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(endpoint("127.0.0.1:12345")?.baseURL.absoluteString, "http://127.0.0.1:12345")
        XCTAssertEqual(endpoint(":9999")?.baseURL.absoluteString, "http://127.0.0.1:9999")
        XCTAssertEqual(endpoint("localhost")?.baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(endpoint("http://localhost")?.baseURL.absoluteString, "http://localhost:80")
        XCTAssertEqual(endpoint("https://127.0.0.1:8443/path")?.baseURL.absoluteString, "https://127.0.0.1:8443")
        XCTAssertEqual(endpoint("[::1]:11434")?.baseURL.absoluteString, "http://[::1]:11434")
        for local in [nil, "localhost:1", "127.5.5.5", "[::1]", "http://127.0.0.1"] {
            XCTAssertEqual(endpoint(local)?.isLoopback, true, "\(local ?? "nil")")
        }
        for remote in ["10.0.0.5:11434", "ollama.example.com", "https://ollama.example.com", "192.168.1.2"] {
            XCTAssertEqual(endpoint(remote)?.isLoopback, false, remote)
        }
        XCTAssertNil(endpoint("host:notaport"))
        XCTAssertNil(endpoint("host:99999"))
        XCTAssertNil(endpoint("bad host"))
        XCTAssertNil(endpoint("[::1"))
    }

    func testOllamaTagsJSONParsing() throws {
        let json = """
        {"models":[
          {"name":"qwen3.5:9b","model":"qwen3.5:9b","modified_at":"2026-03-17T10:21:33.123456789+03:00","size":6600000000,"digest":"x"},
          {"name":"nomic-embed-text:latest","modified_at":"2026-03-17T10:21:33Z","size":274000000},
          {"name":"gpt-oss:cloud","size":0},
          {"model":"fallback:latest","size":5}
        ]}
        """
        let models = try XCTUnwrap(Support.parseOllamaTagsJSON(Data(json.utf8)))
        XCTAssertEqual(models.map(\.name), ["qwen3.5:9b", "nomic-embed-text:latest", "fallback:latest"])
        XCTAssertEqual(models[0].sizeBytes, 6_600_000_000)
        XCTAssertEqual(try XCTUnwrap(models[0].modifiedAt).timeIntervalSince1970, 1_773_732_093.123, accuracy: 0.01)
        XCTAssertNotNil(models[1].modifiedAt)
        XCTAssertNil(models[2].modifiedAt)

        XCTAssertEqual(Support.parseOllamaTagsJSON(Data(#"{"models":null}"#.utf8)), [])
        XCTAssertEqual(Support.parseOllamaTagsJSON(Data(#"{"models":[]}"#.utf8)), [])
        XCTAssertNil(Support.parseOllamaTagsJSON(Data("not json".utf8)))
        XCTAssertNil(Support.parseOllamaTagsJSON(Data(#"{"error":"x"}"#.utf8)))
        XCTAssertNil(Support.parseOllamaTagsJSON(Data("[]".utf8)))
    }

    func testOllamaListTableParsing() {
        let table = """
        NAME                       ID              SIZE      MODIFIED
        qwen3.5:9b                 6488c96fa5fa    6.6 GB    6 months ago
        nomic-embed-text:latest    0a109f422b47    274 MB    6 months ago
        qwen3.5:35b-a3b            3460ffeede54    23 GB     7 months ago
        gpt-oss:cloud              abc             -         now
        """
        let models = Support.parseOllamaListTable(table)
        XCTAssertEqual(models.map(\.name), ["qwen3.5:9b", "nomic-embed-text:latest", "qwen3.5:35b-a3b"])
        XCTAssertEqual(models.map(\.sizeBytes), [6_600_000_000, 274_000_000, 23_000_000_000])
        XCTAssertTrue(models.allSatisfy { $0.modifiedAt == nil })
        XCTAssertTrue(Support.parseOllamaListTable("").isEmpty)
        XCTAssertTrue(Support.parseOllamaListTable("Error: could not connect").isEmpty)
    }

    func testOllamaModelNameValidation() {
        for valid in ["qwen3.5:35b-a3b", "llama3", "library/llama3:8b", "hf.co/org/repo:Q4_K_M", "a@sha256:abc"] {
            XCTAssertTrue(Support.isValidOllamaModelName(valid), valid)
        }
        for invalid in ["", "-rf", "--help", "a b", "a\nb", "a;b", "$(x)", "a`b`", "a'b", "../x y", String(repeating: "a", count: 300)] {
            XCTAssertFalse(Support.isValidOllamaModelName(invalid), invalid)
        }
    }

    func testHubCachePathPrecedenceAndRelativeValuesAreIgnored() {
        let h = "/Users/test"
        XCTAssertEqual(Support.hubCachePath(environment: [:], homePath: h), "/Users/test/.cache/huggingface/hub")
        XCTAssertEqual(Support.hubCachePath(environment: ["XDG_CACHE_HOME": "/x/cache"], homePath: h), "/x/cache/huggingface/hub")
        XCTAssertEqual(Support.hubCachePath(environment: ["HF_HOME": "/hf", "XDG_CACHE_HOME": "/x"], homePath: h), "/hf/hub")
        XCTAssertEqual(Support.hubCachePath(environment: ["HUGGINGFACE_HUB_CACHE": "/legacy", "HF_HOME": "/hf"], homePath: h), "/legacy")
        XCTAssertEqual(
            Support.hubCachePath(environment: ["HF_HUB_CACHE": "/new", "HUGGINGFACE_HUB_CACHE": "/legacy", "HF_HOME": "/hf"], homePath: h),
            "/new"
        )
        XCTAssertEqual(Support.hubCachePath(environment: ["HF_HOME": "~/models"], homePath: h), "/Users/test/models/hub")
        XCTAssertEqual(Support.hubCachePath(environment: ["HF_HUB_CACHE": "relative/path"], homePath: h), "/Users/test/.cache/huggingface/hub")
    }

    func testHubRepoFolderParsing() {
        let model = Support.parseHubRepoFolder("models--black-forest-labs--FLUX.2-klein-9B")
        XCTAssertEqual(model?.kind, .model)
        XCTAssertEqual(model?.repoID, "black-forest-labs/FLUX.2-klein-9B")
        XCTAssertEqual(model?.cliTarget, "model/black-forest-labs/FLUX.2-klein-9B")
        XCTAssertEqual(Support.parseHubRepoFolder("models--gpt2")?.cliTarget, "model/gpt2")
        XCTAssertEqual(Support.parseHubRepoFolder("datasets--org--data")?.cliTarget, "dataset/org/data")
        XCTAssertEqual(Support.parseHubRepoFolder("spaces--org--demo")?.kind, .space)
        XCTAssertNil(Support.parseHubRepoFolder("mlx-community"))
        XCTAssertNil(Support.parseHubRepoFolder("models--"))
        // Odd shapes are still repo folders but are never handed to the CLI.
        XCTAssertNil(Support.parseHubRepoFolder("models--a--b--c")?.cliTarget)
        XCTAssertNil(Support.parseHubRepoFolder("models----x")?.cliTarget)
    }

    func testHubRootPlausibility() {
        let h = "/Users/test"
        XCTAssertTrue(Support.isPlausibleHubRoot("/Users/test/.cache/huggingface/hub", canonicalHome: h))
        XCTAssertTrue(Support.isPlausibleHubRoot("/Volumes/External/hf", canonicalHome: h))
        for bad in ["/", "/Users", h, "/Users/test/Documents", "/Users/test/Library", "/Users/test/Downloads", "relative"] {
            XCTAssertFalse(Support.isPlausibleHubRoot(bad, canonicalHome: h), bad)
        }
    }

    // MARK: - Hugging Face scan

    func testHuggingFaceScanListsReposWithBlobSizeAndApproximateLastUse() async throws {
        let root = try makeHub()
        let refDate = Date(timeIntervalSince1970: 1_700_000_000)
        try makeRepo(root, "models--org--name", blobs: [("aaa", 1000), ("bbb", 500)], refDate: refDate)
        try makeRepo(root, "datasets--org--data", blobs: [("ccc", 2048)], refDate: refDate)
        try makeRepo(root, "spaces--org--empty", blobs: [])
        // Reserved and hidden entries are never rows.
        try fileManager.createDirectory(at: root.appendingPathComponent(".locks"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: root.appendingPathComponent("CACHEDIR.TAG"))

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        XCTAssertEqual(Set(outcome.items.map(\.path)), [
            root.appendingPathComponent("models--org--name").path,
            root.appendingPathComponent("datasets--org--data").path,
        ])
        let model = try XCTUnwrap(outcome.items.first { $0.name == "org/name" })
        XCTAssertEqual(model.size, 1500, "symlinked snapshot files must not be counted twice")
        XCTAssertEqual(try XCTUnwrap(model.lastModified).timeIntervalSince1970, refDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(model.category, .localAIModels)
        XCTAssertFalse(model.isSelected)
        XCTAssertTrue(outcome.items.allSatisfy(\.selectOnlyByHand))
        XCTAssertEqual(outcome.items.first { $0.name == "org/data" }?.size, 2048)
        XCTAssertEqual(outcome.notes.count, 1, "only the approximate-date note; nothing was skipped")
    }

    func testHuggingFaceScanSkipsSymlinkedRepoFolders() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--real", blobs: [("aaa", 100)])
        let elsewhere = sandbox.appendingPathComponent("elsewhere/models--org--target", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data(count: 9999).write(to: elsewhere.appendingPathComponent("blobs/zzz"))
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("models--org--link").path, withDestinationPath: elsewhere.path)

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        XCTAssertEqual(outcome.items.map(\.name), ["org/real"])
    }

    func testHuggingFaceScanReportsReposWhoseBlobsLiveInASharedStoreInsteadOfListingThem() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--normal", blobs: [("aaa", 100)])
        // New-style layout: the repo only holds links into hub/blobs/<xx>/.
        let shared = root.appendingPathComponent("blobs/ab", isDirectory: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: shared.appendingPathComponent("abcdef"))
        let repo = root.appendingPathComponent("models--org--shared", isDirectory: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent("snapshots/rev1"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: repo.appendingPathComponent("blobs/abcdef").path, withDestinationPath: "../../blobs/ab/abcdef")
        try fileManager.createSymbolicLink(atPath: repo.appendingPathComponent("snapshots/rev1/model.bin").path, withDestinationPath: "../../blobs/abcdef")

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        XCTAssertEqual(outcome.items.map(\.name), ["org/normal"])
        XCTAssertFalse(outcome.items.contains { $0.name == "blobs" }, "the shared store itself is reserved")
        XCTAssertEqual(outcome.notes.count, 2, "shared-store note plus approximate-date note")

        let inspection = try XCTUnwrap(Support.inspectHubRepo(atPath: repo.path))
        XCTAssertTrue(inspection.linksOutsideRepo)
        XCTAssertEqual(inspection.storedBytes, 0)
        XCTAssertEqual(inspection.linkedBytes, 4096)
    }

    func testHuggingFaceScanOffersNonStandardFoldersAsReviewRowsWithoutFollowingLinks() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--name", blobs: [("aaa", 100)])
        let custom = root.appendingPathComponent("custom-org", isDirectory: true)
        try fileManager.createDirectory(at: custom.appendingPathComponent("model"), withIntermediateDirectories: true)
        try Data(count: 3000).write(to: custom.appendingPathComponent("model/weights.bin"))
        let external = sandbox.appendingPathComponent("external-model", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(count: 7777).write(to: external.appendingPathComponent("big.bin"))
        try fileManager.createSymbolicLink(atPath: custom.appendingPathComponent("linked").path, withDestinationPath: external.path)
        try fileManager.createDirectory(at: root.appendingPathComponent("empty-org"), withIntermediateDirectories: true)

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        let row = try XCTUnwrap(outcome.items.first { $0.name == "custom-org" })
        XCTAssertEqual(row.size, 3000, "links inside a folder are neither followed nor counted")
        XCTAssertFalse(row.isSelected)
        XCTAssertNil(outcome.items.first { $0.name == "empty-org" })
    }

    func testHuggingFaceScanDoesNotOfferFoldersOfAnUnrecognisedCacheRoot() async throws {
        let root = sandbox.appendingPathComponent("not-a-cache/stuff", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: root.appendingPathComponent("photos/a.jpg"))

        let outcome = LocalAIModels(context: makeContext(env: ["HF_HUB_CACHE": root.path])).scanHuggingFace()

        XCTAssertTrue(outcome.items.isEmpty)
    }

    func testHuggingFaceScanRefusesImplausibleRootsAndRespectsEnvironmentPrecedence() async throws {
        try fileManager.createDirectory(at: home.appendingPathComponent("Documents/stuff"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: home.appendingPathComponent("Documents/stuff/a.bin"))
        XCTAssertTrue(LocalAIModels(context: makeContext(env: ["HF_HUB_CACHE": home.path])).scanHuggingFace().items.isEmpty)
        XCTAssertTrue(LocalAIModels(context: makeContext(env: ["HF_HUB_CACHE": home.appendingPathComponent("Documents").path])).scanHuggingFace().items.isEmpty)

        let custom = sandbox.appendingPathComponent("volume/hf-cache", isDirectory: true)
        try makeRepo(custom, "models--org--moved", blobs: [("aaa", 700)])
        let defaultRoot = try makeHub()
        try makeRepo(defaultRoot, "models--org--default", blobs: [("aaa", 100)])

        let viaHome = LocalAIModels(context: makeContext(env: ["HF_HOME": custom.deletingLastPathComponent().path])).scanHuggingFace()
        XCTAssertTrue(viaHome.items.isEmpty, "HF_HOME/hub does not exist")
        let viaCache = LocalAIModels(context: makeContext(env: ["HF_HUB_CACHE": custom.path])).scanHuggingFace()
        XCTAssertEqual(viaCache.items.map(\.name), ["org/moved"])
        XCTAssertEqual(LocalAIModels(context: makeContext()).scanHuggingFace().items.map(\.name), ["org/default"])
    }

    func testApplicationSupportModelFoldersAreReviewRows() async throws {
        let base = home.appendingPathComponent("Library/Application Support/huggingface", isDirectory: true)
        let mlx = base.appendingPathComponent("models/mlx-community/some-model", isDirectory: true)
        try fileManager.createDirectory(at: mlx, withIntermediateDirectories: true)
        try Data(count: 4000).write(to: mlx.appendingPathComponent("weights.safetensors"))
        try fileManager.createDirectory(at: base.appendingPathComponent("models/empty-org"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appendingPathComponent("gguf_models"), withIntermediateDirectories: true)
        try Data(count: 5000).write(to: base.appendingPathComponent("gguf_models/gemma.gguf"))
        try fileManager.createSymbolicLink(
            atPath: base.appendingPathComponent("gguf_models/link.gguf").path,
            withDestinationPath: base.appendingPathComponent("gguf_models/gemma.gguf").path
        )

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        XCTAssertEqual(Set(outcome.items.map(\.name)), ["models/mlx-community", "gguf_models/gemma.gguf"])
        XCTAssertEqual(outcome.items.first { $0.name == "models/mlx-community" }?.size, 4000)
        XCTAssertTrue(outcome.items.allSatisfy { !$0.isSelected })
    }

    func testApplicationSupportOffersOnlyRecognisableModelData() async throws {
        let base = home.appendingPathComponent("Library/Application Support/huggingface", isDirectory: true)
        let models = base.appendingPathComponent("models", isDirectory: true)
        let gguf = base.appendingPathComponent("gguf_models", isDirectory: true)
        for directory in [models, gguf] { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Recognised.
        try Data(count: 100).write(to: gguf.appendingPathComponent("a.GGUF"))
        try Data(count: 100).write(to: gguf.appendingPathComponent("b.safetensors"))
        try Data(count: 100).write(to: gguf.appendingPathComponent("c.npz"))
        try Data(count: 100).write(to: gguf.appendingPathComponent("d.bin"))
        try fileManager.createDirectory(at: models.appendingPathComponent("e.mlpackage/Data"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: models.appendingPathComponent("e.mlpackage/Data/w"))
        try fileManager.createDirectory(at: models.appendingPathComponent("with-config/deep"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: models.appendingPathComponent("with-config/deep/config.json"))
        try fileManager.createDirectory(at: models.appendingPathComponent("org/repo"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: models.appendingPathComponent("org/repo/model.safetensors"))
        // Not model data.
        try Data(count: 100).write(to: gguf.appendingPathComponent("notes.txt"))
        try Data(count: 100).write(to: models.appendingPathComponent("settings.json"))
        try fileManager.createDirectory(at: models.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: models.appendingPathComponent("photos/a.jpg"))

        let outcome = LocalAIModels(context: makeContext()).scanHuggingFace()

        XCTAssertEqual(Set(outcome.items.map(\.name)), [
            "gguf_models/a.GGUF", "gguf_models/b.safetensors", "gguf_models/c.npz", "gguf_models/d.bin",
            "models/e.mlpackage", "models/with-config", "models/org",
        ])
        XCTAssertEqual(outcome.notes.count, 1, "the skipped-items note; no hub repos so no date note")
    }

    // MARK: - Links into rows

    func testRowsThatAreLinkTargetsAreBlockedAtScanAndRemovalAndNameTheLink() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--name", blobs: [("aaa", 100)])
        let mlx = root.appendingPathComponent("mlx-community", isDirectory: true)
        try fileManager.createDirectory(at: mlx, withIntermediateDirectories: true)
        try Data(count: 50).write(to: mlx.appendingPathComponent("other.bin"))
        let link = mlx.appendingPathComponent("name")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("models--org--name/snapshots/rev1").path)
        let service = LocalAIModels(context: makeContext())

        let scan = service.scanHuggingFace()
        let repo = try XCTUnwrap(scan.items.first { $0.name == "org/name" })
        let folder = try XCTUnwrap(scan.items.first { $0.name == "mlx-community" })
        XCTAssertTrue(try XCTUnwrap(repo.detail).contains("mlx-community/name"), "detail names the linking path: \(repo.detail ?? "")")
        XCTAssertFalse(try XCTUnwrap(folder.detail).contains("mlx-community/name"), "links inside a row do not block that row")

        let engine = CleaningEngine(homeDirectory: home, localAIModels: service)
        let blocked = await engine.cleanItems([repo]) { _ in }
        XCTAssertEqual(blocked.itemsCleaned, 0)
        XCTAssertTrue(try XCTUnwrap(blocked.errors.first).contains(link.path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--name/blobs/aaa").path))

        // The row that holds the link can still go, and then the repo is free to go too.
        let folderResult = await engine.cleanItems([folder]) { _ in }
        XCTAssertEqual(folderResult.itemsCleaned, 1)
        let freed = await engine.cleanItems([repo]) { _ in }
        XCTAssertEqual(freed.itemsCleaned, 1, "\(freed.errors)")
    }

    func testALinkCreatedAfterTheScanBlocksRemovalAndLinksAtTheHubRootAndInApplicationSupportCount() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--name", blobs: [("aaa", 100)])
        try makeRepo(root, "models--org--other", blobs: [("bbb", 100)])
        let service = LocalAIModels(context: makeContext())
        let scan = service.scanHuggingFace()
        let name = try XCTUnwrap(scan.items.first { $0.name == "org/name" })
        let other = try XCTUnwrap(scan.items.first { $0.name == "org/other" })
        XCTAssertFalse(try XCTUnwrap(name.detail).isEmpty)

        // After the scan: a link at the hub root into one repo, and an
        // Application Support link into the other.
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: root.appendingPathComponent("models--org--name/snapshots/rev1").path)
        let support = home.appendingPathComponent("Library/Application Support/huggingface/models", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: support.appendingPathComponent("served").path, withDestinationPath: root.appendingPathComponent("models--org--other").path)

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([name, other]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--name").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--other").path))
    }

    func testCollectSymlinksIsBoundedAndDoesNotFollowLinks() throws {
        let tree = sandbox.appendingPathComponent("walk", isDirectory: true)
        try fileManager.createDirectory(at: tree.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("walk-outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: outside.appendingPathComponent("hidden-link").path, withDestinationPath: tree.path)
        try fileManager.createSymbolicLink(atPath: tree.appendingPathComponent("a/dir-link").path, withDestinationPath: outside.path)
        try fileManager.createSymbolicLink(atPath: tree.appendingPathComponent("a/b/c/deep").path, withDestinationPath: tree.path)
        try fileManager.createSymbolicLink(atPath: tree.appendingPathComponent("dangling").path, withDestinationPath: "/nonexistent-target")

        let all = Support.collectSymlinks(under: tree.path)
        XCTAssertEqual(Set(all.map { ($0.path as NSString).lastPathComponent }), ["dir-link", "deep"], "dangling skipped, linked dirs not entered")
        let shallow = Support.collectSymlinks(under: tree.path, maxDepth: 2)
        XCTAssertEqual(Set(shallow.map { ($0.path as NSString).lastPathComponent }), ["dir-link"])
        XCTAssertEqual(Support.collectSymlinks(under: tree.path, maxEntries: 1).count <= 1, true)
    }

    // MARK: - Bulk selection

    @MainActor
    func testBulkSelectionPathsNeverSelectLocalAIModelRowsButDeselectAndClickStillWork() throws {
        let state = AppState(performStartupTasks: false)
        let rows = ["a", "b", "c"].map { name in
            CleanableItem(
                name: name, path: "/tmp/\(name)", size: 10, category: .localAIModels,
                isSelected: false, lastModified: nil, selectOnlyByHand: true
            )
        }
        let ordinary = CleanableItem(name: "z", path: "/tmp/z", size: 10, category: .localAIModels, isSelected: false, lastModified: nil)
        state.categoryResults[.localAIModels] = CategoryResult(category: .localAIModels, items: rows + [ordinary], totalSize: 40)

        // Select visible.
        state.setSelection(true, for: rows + [ordinary])
        XCTAssertEqual(rows.filter(state.isItemSelected).count, 0)
        XCTAssertTrue(state.isItemSelected(ordinary), "rows without the flag keep bulk behaviour")
        state.deselectAllInCategory(.localAIModels)

        // Select all in category.
        state.selectAllInCategory(.localAIModels)
        XCTAssertEqual(rows.filter(state.isItemSelected).count, 0)

        // The category checkbox.
        state.deselectAllInCategory(.localAIModels)
        state.categoryBinding(for: .localAIModels).wrappedValue = true
        XCTAssertEqual(rows.filter(state.isItemSelected).count, 0)

        // A click on the row itself selects it, and bulk deselect clears it.
        state.itemBinding(for: rows[0]).wrappedValue = true
        XCTAssertTrue(state.isItemSelected(rows[0]))
        state.toggleItem(rows[1])
        XCTAssertTrue(state.isItemSelected(rows[1]))
        state.setSelection(false, for: rows)
        XCTAssertEqual(rows.filter(state.isItemSelected).count, 0)
        state.toggleItem(rows[2])
        state.deselectAllInCategory(.localAIModels)
        XCTAssertFalse(state.isItemSelected(rows[2]))
    }

    // MARK: - Hugging Face removal

    func testRemovingARepoWithoutTheHFCLIDeletesOnlyThatFolder() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--keep", blobs: [("aaa", 100)])
        try makeRepo(root, "models--org--drop", blobs: [("bbb", 200)])
        let service = LocalAIModels(context: makeContext())
        let scan = service.scanHuggingFace()
        let drop = try XCTUnwrap(scan.items.first { $0.name == "org/drop" })

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([drop]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.freedSpace, 200)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--drop").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--keep/blobs/aaa").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.path))
    }

    func testRemovingARepoUsesTheVerifiedHFCLIAndNothingElse() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--keep", blobs: [("aaa", 100)])
        try makeRepo(root, "models--org--drop", blobs: [("bbb", 200)])
        let hf = try writeFakeHF()
        let service = LocalAIModels(context: makeContext(hf: [hf]))
        let drop = try XCTUnwrap(service.scanHuggingFace().items.first { $0.name == "org/drop" })

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([drop]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(invocations(), [
            "cache rm --help",
            "cache rm model/org/drop --cache-dir \(root.path) --yes",
        ])
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--drop").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--keep").path))
    }

    func testAnHFCLIWithoutTheDocumentedFlagsIsNeverDrivenForRemoval() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--drop", blobs: [("bbb", 200)])
        let hf = try writeFakeHF()
        let service = LocalAIModels(context: makeContext(env: ["FAKE_HF_MODE": "old"], hf: [hf]))
        let drop = try XCTUnwrap(service.scanHuggingFace().items.first)

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([drop]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(invocations(), ["cache rm --help"], "only the flag probe ran")
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--drop").path))
    }

    func testRemovalFallsBackToTheValidatedFolderWhenTheHFCLIFailsOrDoesNothing() async throws {
        for mode in ["noop", "fail"] {
            let root = try makeHub()
            try makeRepo(root, "models--org--drop", blobs: [("bbb", 200)])
            let hf = try writeFakeHF()
            let service = LocalAIModels(context: makeContext(env: ["FAKE_HF_MODE": mode], hf: [hf]))
            let drop = try XCTUnwrap(service.scanHuggingFace().items.first)

            let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([drop]) { _ in }

            XCTAssertEqual(result.itemsCleaned, 1, mode)
            XCTAssertTrue(result.errors.isEmpty, "\(mode): \(result.errors)")
            XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--drop").path), mode)
            try fileManager.removeItem(at: root.deletingLastPathComponent())
        }
    }

    func testFallbackAfterAFailedHFCLIRunsTheFullInspectionAgain() async throws {
        for mode in ["tamper", "linkin"] {
            let root = try makeHub()
            try makeRepo(root, "models--org--drop", blobs: [("bbb", 200)])
            let hf = try writeFakeHF()
            let service = LocalAIModels(context: makeContext(env: ["FAKE_HF_MODE": mode], hf: [hf]))
            let drop = try XCTUnwrap(service.scanHuggingFace().items.first)

            let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([drop]) { _ in }

            XCTAssertEqual(result.itemsCleaned, 0, mode)
            XCTAssertEqual(result.errors.count, 1, mode)
            XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--drop/blobs/bbb").path), mode)
            try fileManager.removeItem(at: root.deletingLastPathComponent())
        }
    }

    func testRemovalRefusesASymlinkedRepoFolderAndLeavesTheTargetUntouched() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--real", blobs: [("aaa", 100)])
        let precious = sandbox.appendingPathComponent("precious/models--org--target", isDirectory: true)
        try fileManager.createDirectory(at: precious.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try Data(count: 123).write(to: precious.appendingPathComponent("blobs/keep"))
        let link = root.appendingPathComponent("models--org--link")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: precious.path)

        let result = await CleaningEngine(homeDirectory: home, localAIModels: LocalAIModels(context: makeContext()))
            .cleanItems([forgedItem(link.path)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: precious.appendingPathComponent("blobs/keep").path))
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: link.path), "the link itself is left alone")
    }

    func testRemovalRefusesEverythingThatIsNotADirectChildOfAKnownModelRoot() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--real", blobs: [("aaa", 100)])
        let precious = home.appendingPathComponent("Documents/precious", isDirectory: true)
        try fileManager.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data(count: 10).write(to: precious.appendingPathComponent("file.txt"))
        try fileManager.createDirectory(at: root.appendingPathComponent(".locks"), withIntermediateDirectories: true)

        let refused = [
            precious.path,
            root.path,
            root.deletingLastPathComponent().path,
            home.path,
            root.appendingPathComponent("models--org--real/snapshots").path,
            root.appendingPathComponent("models--org--real/blobs/aaa").path,
            root.appendingPathComponent("blobs").path,
            root.appendingPathComponent(".locks").path,
            root.path + "/../hub/models--org--real",
            root.path + "/models--org--real/",
            root.path + "/models--org--missing",
            "relative/models--org--real",
            "",
            "/",
        ]
        let engine = CleaningEngine(homeDirectory: home, localAIModels: LocalAIModels(context: makeContext()))

        let result = await engine.cleanItems(refused.map(forgedItem)) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, refused.count)
        XCTAssertTrue(result.requiresAdmin.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: precious.appendingPathComponent("file.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--real/blobs/aaa").path))
    }

    func testRemovalRefusesAReposWhoseFilesLiveInASharedStore() async throws {
        let root = try makeHub()
        let shared = root.appendingPathComponent("blobs/ab", isDirectory: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: shared.appendingPathComponent("abcdef"))
        let repo = root.appendingPathComponent("models--org--shared", isDirectory: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: repo.appendingPathComponent("blobs/abcdef").path, withDestinationPath: "../../blobs/ab/abcdef")
        let hf = try writeFakeHF()

        let result = await CleaningEngine(homeDirectory: home, localAIModels: LocalAIModels(context: makeContext(hf: [hf])))
            .cleanItems([forgedItem(repo.path)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: shared.appendingPathComponent("abcdef").path))
        XCTAssertTrue(invocations().isEmpty, "the CLI is not even asked")
    }

    func testNonStandardFolderRemovalDeletesOneFolderAndNeverFollowsLinksInside() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--name", blobs: [("aaa", 100)])
        let custom = root.appendingPathComponent("custom-org", isDirectory: true)
        try fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data(count: 3000).write(to: custom.appendingPathComponent("weights.bin"))
        let external = sandbox.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(count: 50).write(to: external.appendingPathComponent("keep.bin"))
        try fileManager.createSymbolicLink(atPath: custom.appendingPathComponent("linked").path, withDestinationPath: external.path)
        // A link into a sibling repo's snapshot, like ~/.cache/.../mlx-community/<model>.
        try fileManager.createSymbolicLink(
            atPath: custom.appendingPathComponent("repo-link").path,
            withDestinationPath: root.appendingPathComponent("models--org--name/snapshots/rev1").path
        )
        let service = LocalAIModels(context: makeContext())
        let row = try XCTUnwrap(service.scanHuggingFace().items.first { $0.name == "custom-org" })

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: custom.path))
        XCTAssertTrue(fileManager.fileExists(atPath: external.appendingPathComponent("keep.bin").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("models--org--name/blobs/aaa").path))
        XCTAssertTrue(invocations().isEmpty)
    }

    func testApplicationSupportEntriesAreRemovedButASymlinkedRootIsRefused() async throws {
        let base = home.appendingPathComponent("Library/Application Support/huggingface", isDirectory: true)
        try fileManager.createDirectory(at: base.appendingPathComponent("gguf_models"), withIntermediateDirectories: true)
        let model = base.appendingPathComponent("gguf_models/gemma.gguf")
        let sibling = base.appendingPathComponent("gguf_models/other.gguf")
        try Data(count: 5000).write(to: model)
        try Data(count: 10).write(to: sibling)
        let service = LocalAIModels(context: makeContext())
        let row = try XCTUnwrap(service.scanHuggingFace().items.first { $0.name == "gguf_models/gemma.gguf" })

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: model.path))
        XCTAssertTrue(fileManager.fileExists(atPath: sibling.path))

        // Replace the whole root with a link to somewhere else: nothing under it may be removed.
        let elsewhere = sandbox.appendingPathComponent("elsewhere-gguf", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(count: 77).write(to: elsewhere.appendingPathComponent("victim.gguf"))
        try fileManager.removeItem(at: base.appendingPathComponent("gguf_models"))
        try fileManager.createSymbolicLink(atPath: base.appendingPathComponent("gguf_models").path, withDestinationPath: elsewhere.path)

        let refused = await CleaningEngine(homeDirectory: home, localAIModels: service)
            .cleanItems([forgedItem(base.appendingPathComponent("gguf_models/victim.gguf").path)]) { _ in }

        XCTAssertEqual(refused.itemsCleaned, 0)
        XCTAssertEqual(refused.errors.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: elsewhere.appendingPathComponent("victim.gguf").path))
    }

    func testLocalAIModelRowsNeverReachTheGenericDeleteOrAdminPass() async throws {
        // A forged row inside an allow-listed generic root (~/.cache) must not be
        // deletable through the generic route.
        let cache = home.appendingPathComponent(".cache/other", isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 10).write(to: cache.appendingPathComponent("file"))
        let engine = CleaningEngine(homeDirectory: home, localAIModels: LocalAIModels(context: makeContext()))

        let result = await engine.cleanItems([forgedItem(cache.path)]) { _ in }
        let admin = await engine.cleanWithAdminPrivileges(items: [forgedItem(cache.path)])

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(admin.itemsCleaned, 0)
        XCTAssertEqual(admin.errors.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: cache.appendingPathComponent("file").path))
    }

    // MARK: - Ollama scan

    func testOllamaScanUsesTheAPIAndNeverTheCLIWhenTheServerAnswers() async throws {
        let ollama = try writeFakeOllama()
        let requested = LockedBox<[URLRequest]>([])
        let json = """
        {"models":[
          {"name":"qwen3.5:9b","modified_at":"2026-03-17T10:21:33.5Z","size":6600000000},
          {"name":"qwen3.5:35b-a3b","modified_at":"2026-03-10T08:00:00Z","size":23000000000},
          {"name":"bad name;rm","size":10}
        ]}
        """
        let context = makeContext(ollama: [ollama]) { request in
            requested.mutate { $0.append(request) }
            return (Data(json.utf8), 200)
        }

        let outcome = await LocalAIModels(context: context).scanOllama()

        XCTAssertEqual(outcome.items.map(\.name), ["qwen3.5:35b-a3b", "qwen3.5:9b"], "largest first; unsafe names dropped")
        XCTAssertEqual(outcome.items.map(\.size), [23_000_000_000, 6_600_000_000])
        XCTAssertEqual(outcome.items.map(\.path), ["ollama-model:qwen3.5:35b-a3b", "ollama-model:qwen3.5:9b"])
        XCTAssertTrue(outcome.items.allSatisfy { !$0.isSelected && $0.selectOnlyByHand && $0.category == .localAIModels && $0.lastModified != nil })
        XCTAssertTrue(outcome.notes.isEmpty)
        XCTAssertEqual(requested.value.map { $0.url?.absoluteString }, ["http://127.0.0.1:11434/api/tags"])
        XCTAssertEqual(requested.value.first?.httpMethod, "GET")
        XCTAssertTrue(invocations().isEmpty)
    }

    func testOllamaScanRespectsOllamaHost() async throws {
        let seen = LockedBox<String?>(nil)
        let context = makeContext(env: ["OLLAMA_HOST": "127.0.0.1:12345"]) { request in
            seen.mutate { $0 = request.url?.absoluteString }
            return (Data(#"{"models":[]}"#.utf8), 200)
        }
        _ = await LocalAIModels(context: context).scanOllama()
        XCTAssertEqual(seen.value, "http://127.0.0.1:12345/api/tags")
    }

    func testOllamaScanFallsBackToTheCLIWhenTheAPIIsUnreachable() async throws {
        let ollama = try writeFakeOllama()

        let outcome = await LocalAIModels(context: makeContext(ollama: [ollama])).scanOllama()

        XCTAssertEqual(outcome.items.map(\.name), ["qwen3.5:9b", "nomic-embed-text:latest"])
        XCTAssertEqual(outcome.items.map(\.size), [6_600_000_000, 274_000_000])
        XCTAssertEqual(invocations(), ["list"])
        XCTAssertTrue(outcome.notes.isEmpty)
    }

    func testOllamaScanWithoutServerOrCLIYieldsNoRowsAndANote() async throws {
        let outcome = await LocalAIModels(context: makeContext()).scanOllama()
        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.notes.count, 1)
    }

    func testOllamaScanDoesNotWaitTwiceWhenTheServerTimesOut() async throws {
        let ollama = try writeFakeOllama()
        let context = makeContext(ollama: [ollama]) { _ in throw URLError(.timedOut) }

        let outcome = await LocalAIModels(context: context).scanOllama()

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertTrue(invocations().isEmpty, "a hung server would hang `ollama list` too")
    }

    func testOllamaScanGivesUpOnAHangingCLI() async throws {
        let ollama = try writeScript("ollama-hang", #"echo "$*" >> "$FAKE_LOG"; exec sleep 30"#)
        let started = Date()

        let outcome = await LocalAIModels(context: makeContext(ollama: [ollama], listTimeout: 0.5)).scanOllama()

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(invocations(), ["list"])
    }

    func testOllamaScanReportsRemoteHostsInsteadOfTalkingToThem() async throws {
        let ollama = try writeFakeOllama()
        let fetched = LockedBox(0)
        let context = makeContext(env: ["OLLAMA_HOST": "10.1.2.3:11434"], ollama: [ollama]) { _ in
            fetched.mutate { $0 += 1 }
            return (Data(), 200)
        }

        let outcome = await LocalAIModels(context: context).scanOllama()

        XCTAssertTrue(outcome.items.isEmpty)
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertEqual(fetched.value, 0)
        XCTAssertTrue(invocations().isEmpty)
    }

    // MARK: - Ollama removal

    func testOllamaRemovalRunsOllamaRmWithTheModelNameAndNothingElse() async throws {
        let ollama = try writeFakeOllama()
        let service = LocalAIModels(context: makeContext(ollama: [ollama], fetch: tagsFetch([("qwen3.5:9b", digest9b)])))
        let item = ollamaItem("qwen3.5:9b", size: 6_600_000_000)

        let result = await CleaningEngine(homeDirectory: home, localAIModels: service).cleanItems([item]) { _ in }

        XCTAssertEqual(invocations(), ["rm qwen3.5:9b"])
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.freedSpace, 6_600_000_000)
        XCTAssertEqual(result.cleanedPaths, [item.path])
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.requiresAdmin.isEmpty)
    }

    func testOllamaRemovalRefusesUnsafeNamesAndRemoteHosts() async throws {
        let ollama = try writeFakeOllama()
        let service = LocalAIModels(context: makeContext(ollama: [ollama]))
        for name in ["-rf", "--all", "a b", "x;y", "", "$(id)"] {
            let outcome = await service.removeOllamaModel(name: name, expectedDigest: digest9b, reportedSize: 1)
            XCTAssertFalse(outcome.cleaned, name)
            XCTAssertNotNil(outcome.error, name)
        }
        let remote = LocalAIModels(context: makeContext(env: ["OLLAMA_HOST": "ollama.example.com"], ollama: [ollama]))
        let outcome = await remote.removeOllamaModel(name: "qwen3.5:9b", expectedDigest: digest9b, reportedSize: 1)
        XCTAssertFalse(outcome.cleaned)
        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(invocations().isEmpty)
    }

    func testOllamaRemovalReportsFailuresAndTimeouts() async throws {
        let failing = try writeScript("ollama-fail", #"echo "$*" >> "$FAKE_LOG"; echo "Error: model not found" >&2; exit 1"#)
        let outcome = await LocalAIModels(context: makeContext(ollama: [failing], fetch: tagsFetch([("gone:latest", digest9b)])))
            .removeOllamaModel(name: "gone:latest", expectedDigest: digest9b, reportedSize: 5)
        XCTAssertFalse(outcome.cleaned)
        XCTAssertEqual(outcome.freed, 0)
        XCTAssertTrue(try XCTUnwrap(outcome.error).contains("model not found"))

        let down = try writeScript("ollama-down", #"echo "Error: could not connect to ollama server" >&2; exit 1"#)
        let downOutcome = await LocalAIModels(context: makeContext(ollama: [down], fetch: tagsFetch([("x:latest", digest9b)])))
            .removeOllamaModel(name: "x:latest", expectedDigest: digest9b, reportedSize: 5)
        XCTAssertFalse(downOutcome.cleaned)
        XCTAssertNotNil(downOutcome.error)

        let hang = try writeScript("ollama-hang-rm", #"exec sleep 30"#)
        let started = Date()
        let hung = await LocalAIModels(context: makeContext(ollama: [hang], removeTimeout: 0.5, fetch: tagsFetch([("x:latest", digest9b)])))
            .removeOllamaModel(name: "x:latest", expectedDigest: digest9b, reportedSize: 5)
        XCTAssertFalse(hung.cleaned)
        XCTAssertNotNil(hung.error)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testOllamaRemovalFallsBackToTheDeleteAPIWhenThereIsNoCLI() async throws {
        let seen = LockedBox<[URLRequest]>([])
        let context = makeContext(fetch: tagsFetch([("qwen3.5:9b", digest9b)]) { request in seen.mutate { $0.append(request) } })

        let outcome = await LocalAIModels(context: context)
            .removeOllamaModel(name: "qwen3.5:9b", expectedDigest: digest9b, reportedSize: 42)

        XCTAssertTrue(outcome.cleaned)
        XCTAssertEqual(outcome.freed, 42)
        let deletes = seen.value.filter { $0.httpMethod == "DELETE" }
        let request = try XCTUnwrap(deletes.first)
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/delete")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["model"], "qwen3.5:9b")

        let refused = LocalAIModels(context: makeContext(fetch: tagsFetch([("qwen3.5:9b", digest9b)], deleteStatus: 404)))
        let notFound = await refused.removeOllamaModel(name: "qwen3.5:9b", expectedDigest: digest9b, reportedSize: 42)
        XCTAssertFalse(notFound.cleaned)
        XCTAssertNotNil(notFound.error)
    }

    func testOllamaRemovalSkipsAModelWhoseDigestChangedSinceTheScan() async throws {
        let ollama = try writeFakeOllama()
        let repulled = String(repeating: "f", count: 64)
        let seen = LockedBox<[URLRequest]>([])
        let context = makeContext(ollama: [ollama], fetch: tagsFetch([("qwen3.5:9b", repulled)]) { request in seen.mutate { $0.append(request) } })

        let outcome = await LocalAIModels(context: context)
            .removeOllamaModel(name: "qwen3.5:9b", expectedDigest: digest9b, reportedSize: 1)

        XCTAssertFalse(outcome.cleaned)
        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(invocations().isEmpty, "ollama rm must not run")
        XCTAssertTrue(seen.value.filter { $0.httpMethod == "DELETE" }.isEmpty)
    }

    func testOllamaRemovalSkipsWhenTheDigestIsMissingTheModelIsGoneOrTheServerIsSilent() async throws {
        let ollama = try writeScript("ollama-never-rm", #"echo "$*" >> "$FAKE_LOG"; exit 1"#)
        // No digest recorded at scan time.
        let noDigest = await LocalAIModels(context: makeContext(ollama: [ollama], fetch: tagsFetch([("a:latest", digest9b)])))
            .removeOllamaModel(name: "a:latest", expectedDigest: nil, reportedSize: 1)
        XCTAssertFalse(noDigest.cleaned)
        // The tag is no longer listed.
        let gone = await LocalAIModels(context: makeContext(ollama: [ollama], fetch: tagsFetch([("other:latest", digest9b)])))
            .removeOllamaModel(name: "a:latest", expectedDigest: digest9b, reportedSize: 1)
        XCTAssertFalse(gone.cleaned)
        // Neither API nor `ollama list` can confirm.
        let silent = await LocalAIModels(context: makeContext(ollama: [ollama]))
            .removeOllamaModel(name: "a:latest", expectedDigest: digest9b, reportedSize: 1)
        XCTAssertFalse(silent.cleaned)
        XCTAssertFalse(invocations().contains { $0.hasPrefix("rm") }, "ollama rm never ran: \(invocations())")
    }

    func testOllamaRemovalConfirmsThroughTheListIDColumnWhenOnlyTheCLIAnswers() async throws {
        let ollama = try writeFakeOllama()
        let service = LocalAIModels(context: makeContext(ollama: [ollama]))

        // The CLI lists 6488c96fa5fa for qwen3.5:9b; the scan recorded the full digest.
        let ok = await service.removeOllamaModel(name: "qwen3.5:9b", expectedDigest: digest9b, reportedSize: 7)
        XCTAssertTrue(ok.cleaned)
        XCTAssertEqual(invocations(), ["list", "rm qwen3.5:9b"])

        let changed = await service.removeOllamaModel(name: "qwen3.5:9b", expectedDigest: String(repeating: "a", count: 64), reportedSize: 7)
        XCTAssertFalse(changed.cleaned)
        XCTAssertEqual(invocations(), ["list", "rm qwen3.5:9b", "list"])
    }

    func testOllamaDigestMatching() {
        XCTAssertTrue(Support.ollamaDigestsMatch(digest9b, "6488c96fa5fa"))
        XCTAssertTrue(Support.ollamaDigestsMatch("6488C96FA5FA", digest9b))
        XCTAssertFalse(Support.ollamaDigestsMatch(digest9b, "6488c96fa5fb"))
        XCTAssertFalse(Support.ollamaDigestsMatch("6488", "6488"), "too short to identify a model")
        XCTAssertFalse(Support.ollamaDigestsMatch(nil, digest9b))
        XCTAssertEqual(Support.normalizedOllamaDigest("sha256:ABCDEF012345"), "abcdef012345")
        XCTAssertNil(Support.normalizedOllamaDigest("-"))
        XCTAssertNil(Support.normalizedOllamaDigest("xyz"))
    }

    func testOllamaScanRecordsTheDigestInTheRowPathAndKeepsRowsOutOfBulkSelection() async throws {
        let context = makeContext(fetch: tagsFetch([("qwen3.5:9b", digest9b)]))

        let outcome = await LocalAIModels(context: context).scanOllama()

        let item = try XCTUnwrap(outcome.items.first)
        XCTAssertEqual(item.path, "ollama-model:qwen3.5:9b#\(digest9b)")
        XCTAssertEqual(item.ollamaModelName, "qwen3.5:9b")
        XCTAssertEqual(item.ollamaModelDigest, digest9b)
        XCTAssertTrue(item.selectOnlyByHand)
    }

    // MARK: - Redirects

    func testLiveFetchDoesNotFollowRedirects() async throws {
        RedirectingProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let fetch = LocalAIModelsContext.liveFetch(configuration: configuration)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/delete")!)
        request.httpMethod = "DELETE"
        request.httpBody = Data(#"{"model":"x"}"#.utf8)

        let status: Int?
        do { status = try await fetch(request).status } catch { status = nil }

        XCTAssertNotEqual(status, 200)
        XCTAssertEqual(RedirectingProtocol.loadedURLs, ["http://127.0.0.1:11434/api/delete"], "the redirect target was never requested")
    }

    func testRedirectDelegateRefusesEveryRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://127.0.0.1:1/")!, statusCode: 307, httpVersion: nil, headerFields: ["Location": "http://example.com/"]))
        var answered = false
        var followed: URLRequest?
        RefuseRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "http://example.com/")!)) {
            answered = true
            followed = $0
        }
        XCTAssertTrue(answered)
        XCTAssertNil(followed)
        session.invalidateAndCancel()
    }

    // MARK: - ScanEngine wiring

    func testScanEngineReturnsUnselectedRowsAndNotesForTheCategory() async throws {
        let root = try makeHub()
        try makeRepo(root, "models--org--name", blobs: [("aaa", 1500)])
        let service = LocalAIModels(context: makeContext())

        let result = await ScanEngine(homeDirectory: home, localAIModels: service).scanCategory(.localAIModels)

        XCTAssertEqual(result.category, .localAIModels)
        XCTAssertEqual(result.items.map(\.name), ["org/name"])
        XCTAssertEqual(result.totalSize, 1500)
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelected })
        XCTAssertGreaterThanOrEqual(result.notes.count, 2, "Ollama unavailable plus approximate dates")
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeHub() throws -> URL {
        let root = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `blobs/<hash>` files, `snapshots/rev1/<hash>.bin -> ../../blobs/<hash>`
    /// links (one nested a level deeper) and `refs/main`.
    private func makeRepo(
        _ root: URL,
        _ folder: String,
        blobs: [(String, Int)],
        refDate: Date = Date(timeIntervalSince1970: 1_600_000_000)
    ) throws {
        let repo = root.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        guard !blobs.isEmpty else { return }
        let revision = repo.appendingPathComponent("snapshots/rev1", isDirectory: true)
        try fileManager.createDirectory(at: revision.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for (index, (hash, size)) in blobs.enumerated() {
            try Data(count: size).write(to: repo.appendingPathComponent("blobs/\(hash)"))
            if index == 0 {
                try fileManager.createSymbolicLink(atPath: revision.appendingPathComponent("\(hash).bin").path, withDestinationPath: "../../blobs/\(hash)")
            } else {
                try fileManager.createSymbolicLink(atPath: revision.appendingPathComponent("nested/\(hash).bin").path, withDestinationPath: "../../../blobs/\(hash)")
            }
        }
        let ref = repo.appendingPathComponent("refs/main")
        try Data("rev1".utf8).write(to: ref)
        try fileManager.setAttributes([.modificationDate: refDate], ofItemAtPath: ref.path)
        try fileManager.setAttributes([.modificationDate: refDate.addingTimeInterval(-3600)], ofItemAtPath: revision.path)
    }

    private func makeContext(
        env extra: [String: String] = [:],
        ollama: [String] = [],
        hf: [String] = [],
        listTimeout: TimeInterval = 10,
        removeTimeout: TimeInterval = 20,
        fetch: LocalAIModelsContext.HTTPFetcher? = nil
    ) -> LocalAIModelsContext {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "FAKE_LOG": logFile.path,
            "FAKE_SANDBOX": sandbox.path,
        ]
        environment.merge(extra) { _, new in new }
        var context = LocalAIModelsContext.live(homeDirectory: home, environment: environment)
        // Only fakes are ever executable, and the network is a stub.
        context.ollamaExecutableCandidates = ollama
        context.hfExecutableCandidates = hf
        context.listTimeout = listTimeout
        context.removeTimeout = removeTimeout
        context.fetch = fetch ?? { _ in throw URLError(.cannotConnectToHost) }
        return context
    }

    private func forgedItem(_ path: String) -> CleanableItem {
        CleanableItem(name: "forged", path: path, size: 1, category: .localAIModels, isSelected: true, lastModified: nil)
    }

    private let digest9b = "6488c96fa5fa" + String(repeating: "0", count: 52)

    private func ollamaItem(_ name: String, size: Int64, digest: String? = nil) -> CleanableItem {
        CleanableItem(
            name: name, path: CleanableItem.ollamaModelPathPrefix + name + "#" + (digest ?? digest9b),
            size: size, category: .localAIModels, isSelected: true, lastModified: nil
        )
    }

    /// Stub server: GET answers `/api/tags` with these (name, digest) pairs,
    /// any other method gets `deleteStatus`. `onRequest` sees every request.
    private func tagsFetch(
        _ models: [(String, String)],
        deleteStatus: Int = 200,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) -> LocalAIModelsContext.HTTPFetcher {
        let entries = models.map { #"{"name":"\#($0.0)","size":1000,"digest":"\#($0.1)"}"# }.joined(separator: ",")
        let body = Data(#"{"models":[\#(entries)]}"#.utf8)
        return { request in
            onRequest?(request)
            if request.httpMethod == "DELETE" { return (Data(), deleteStatus) }
            return (body, 200)
        }
    }

    @discardableResult
    private func writeScript(_ name: String, _ body: String) throws -> String {
        let url = tools.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func writeFakeOllama() throws -> String {
        try writeScript("ollama", """
        echo "$*" >> "$FAKE_LOG"
        case "$1" in
          list)
            printf 'NAME                       ID              SIZE      MODIFIED\\n'
            printf 'qwen3.5:9b                 6488c96fa5fa    6.6 GB    6 months ago\\n'
            printf 'nomic-embed-text:latest    0a109f422b47    274 MB    6 months ago\\n'
            exit 0 ;;
          rm) exit 0 ;;
        esac
        exit 2
        """)
    }

    /// Mimics `hf cache rm <type>/<org>/<name> --cache-dir <dir> --yes` for
    /// cache dirs inside the test sandbox only. FAKE_HF_MODE: old (help has no
    /// flags), noop (reports success, removes nothing), fail (exit 1), tamper
    /// and linkin (fail after changing the cache; see the script).
    private func writeFakeHF() throws -> String {
        try writeScript("hf", """
        echo "$*" >> "$FAKE_LOG"
        if [ "$1" = cache ] && [ "$2" = rm ] && [ "$3" = "--help" ]; then
          if [ "$FAKE_HF_MODE" = old ]; then echo "Usage: hf cache rm TARGETS..."; else echo "Usage: hf cache rm [OPTIONS] TARGETS..."; echo "  --cache-dir TEXT"; echo "  -y, --yes"; fi
          exit 0
        fi
        if [ "$1" = cache ] && [ "$2" = rm ]; then
          case "$FAKE_HF_MODE" in noop) exit 0 ;; fail) exit 1 ;; esac
          case "$5" in "$FAKE_SANDBOX"/*) ;; *) exit 3 ;; esac
          folder=$(echo "$3" | sed -e 's#^model/#models--#' -e 's#^dataset/#datasets--#' -e 's#^space/#spaces--#' -e 's#/#--#g')
          # tamper: fail after pointing a link inside the repo at a folder outside it.
          # linkin: fail after creating a link elsewhere in the cache that points into the repo.
          if [ "$FAKE_HF_MODE" = tamper ]; then ln -s "$FAKE_SANDBOX" "$5/$folder/blobs/escape"; exit 1; fi
          if [ "$FAKE_HF_MODE" = linkin ]; then ln -s "$5/$folder" "$5/late-link"; exit 1; fi
          rm -rf "$5/$folder"
          exit 0
        fi
        exit 2
        """)
    }

    private func invocations() -> [String] {
        ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}

/// Answers every request with a 307 to a second URL and records each URL that
/// is actually loaded, so a followed redirect shows up as a second entry.
private final class RedirectingProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [String] = []

    static var loadedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    static func reset() {
        lock.lock()
        urls = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.urls.append(request.url?.absoluteString ?? "")
        Self.lock.unlock()
        guard let url = request.url else { return }
        if url.host == "127.0.0.1", url.port == 11434 {
            let target = URL(string: "http://127.0.0.2:9/stolen")!
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
