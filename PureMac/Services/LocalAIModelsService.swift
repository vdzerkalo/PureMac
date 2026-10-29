import Foundation

/// Everything the Local AI Models category needs from the outside world,
/// injectable so tests never start a real `ollama` or `hf` and never open a
/// socket.
struct LocalAIModelsContext: Sendable {
    typealias CommandRunner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) async throws -> BrewProcessOutput
    typealias HTTPFetcher = @Sendable (_ request: URLRequest) async throws -> (data: Data, status: Int)

    var homeDirectory: URL
    var environment: [String: String]
    var ollamaExecutableCandidates: [String]
    var hfExecutableCandidates: [String]
    /// Budget for `ollama list`, `hf cache rm --help` and the API listing.
    var listTimeout: TimeInterval = 15
    /// Budget for `ollama rm`, `hf cache rm` and the API delete.
    var removeTimeout: TimeInterval = 120
    var runCommand: CommandRunner
    var fetch: HTTPFetcher

    static func live(
        homeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalAIModelsContext {
        let home = homeDirectory.path
        return LocalAIModelsContext(
            homeDirectory: homeDirectory,
            environment: environment,
            ollamaExecutableCandidates: [
                "/usr/local/bin/ollama",
                "/opt/homebrew/bin/ollama",
                "/Applications/Ollama.app/Contents/Resources/ollama",
            ],
            hfExecutableCandidates: [
                "/opt/homebrew/bin/hf",
                "/usr/local/bin/hf",
                // pipx and `uv tool install` put console scripts here.
                "\(home)/.local/bin/hf",
            ],
            runCommand: { executable, arguments, timeout, environment in
                try await BrewProcessRunner.run(
                    executableURL: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environment: environment
                )
            },
            fetch: liveFetch()
        )
    }

    /// Loopback HTTP with redirects refused. Whatever listens on the port could
    /// answer a `DELETE /api/delete` with a 307 to another host, and URLSession
    /// would resend the method and the model name there. A refused redirect
    /// comes back as its 3xx status, which callers treat as a failure.
    /// `configuration` is a parameter so tests can add a stub protocol.
    static func liveFetch(configuration: URLSessionConfiguration = .ephemeral) -> HTTPFetcher {
        { request in
            // Per-request limits are set on each URLRequest; these are ceilings.
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 130
            configuration.waitsForConnectivity = false
            // Loopback only: never let a system proxy see the request.
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Scans and removes local AI models: Ollama through its own CLI/API, and the
/// Hugging Face caches through the `hf` CLI or a validated single-folder
/// delete. This is the only code path that removes Local AI Models rows; the
/// generic `CleaningEngine` allow-list is deliberately not involved.
struct LocalAIModels: Sendable {
    /// Manual Smart Scan also scans models (`CleaningCategory.smartScanOptInKey`).
    static let includeInSmartScanKey = "settings.cleaning.localAIModels.includeInSmartScan"

    let context: LocalAIModelsContext

    typealias Support = LocalAIModelsSupport

    struct ScanOutcome {
        var items: [CleanableItem] = []
        var notes: [String] = []
    }

    struct RemovalOutcome: Equatable {
        var freed: Int64 = 0
        var cleaned = false
        var error: String?
    }

    private var fileManager: FileManager { .default }

    private var homePath: String {
        Support.canonicalPath(context.homeDirectory.path) ?? context.homeDirectory.path
    }

    // MARK: - Scan

    func scan() async -> ScanOutcome {
        var outcome = ScanOutcome()
        let ollama = await scanOllama()
        let hub = scanHuggingFace()
        outcome.items = ollama.items + hub.items
        outcome.notes = ollama.notes + hub.notes
        return outcome
    }

    // MARK: Ollama

    private enum OllamaListing {
        /// `viaAPI` is false when the models came from `ollama list`.
        case models([LocalAIModelsSupport.OllamaModel], viaAPI: Bool)
        case unavailable
        case remoteHost
    }

    func scanOllama() async -> ScanOutcome {
        switch await listOllamaModels() {
        case .remoteHost:
            return ScanOutcome(notes: [
                String(localized: "OLLAMA_HOST points to another machine. PureMac only manages models on this Mac."),
            ])
        case .unavailable:
            return ScanOutcome(notes: [
                String(localized: "Ollama is not running or the ollama command was not found. Start Ollama and scan again to list its models."),
            ])
        case .models(let models, _):
            let detail = String(localized: "Ollama model · freed space can be smaller when models share files")
            let items = models
                .filter { Support.isValidOllamaModelName($0.name) }
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .map { model in
                    CleanableItem(
                        name: model.name,
                        // The digest rides along so removal can confirm it is
                        // still the same model (see `confirmOllamaDigest`).
                        path: CleanableItem.ollamaModelPathPrefix + model.name + (model.digest.map { "#" + $0 } ?? ""),
                        size: model.sizeBytes,
                        category: .localAIModels,
                        isSelected: false,
                        lastModified: model.modifiedAt,
                        detail: detail,
                        selectOnlyByHand: true
                    )
                }
            return ScanOutcome(items: items)
        }
    }

    private func listOllamaModels() async -> OllamaListing {
        guard let endpoint = Support.ollamaEndpoint(environment: context.environment) else {
            Logger.shared.log("Local AI Models: OLLAMA_HOST could not be parsed", level: .warning)
            return .unavailable
        }
        guard endpoint.isLoopback else {
            Logger.shared.log("Local AI Models: OLLAMA_HOST is not a loopback address; skipping Ollama", level: .info)
            return .remoteHost
        }

        // The API reports exact byte sizes and ISO dates; the CLI table only
        // has rounded sizes and relative times, so it is the fallback.
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = min(context.listTimeout, 5)
        do {
            let response = try await context.fetch(request)
            if response.status == 200, let models = Support.parseOllamaTagsJSON(response.data) {
                return .models(models, viaAPI: true)
            }
            Logger.shared.log("Local AI Models: /api/tags answered \(response.status) with an unreadable body", level: .warning)
        } catch let error as URLError where error.code == .timedOut {
            // A hung server would hang `ollama list` too; do not wait twice.
            Logger.shared.log("Local AI Models: /api/tags timed out", level: .warning)
            return .unavailable
        } catch {
            Logger.shared.log("Local AI Models: /api/tags failed: \(error.localizedDescription)", level: .info)
        }

        guard let executable = firstExecutable(in: context.ollamaExecutableCandidates) else { return .unavailable }
        do {
            let output = try await context.runCommand(
                URL(fileURLWithPath: executable), ["list"], context.listTimeout, context.environment
            )
            guard output.status == 0, let text = String(data: output.stdout, encoding: .utf8) else {
                Logger.shared.log("Local AI Models: ollama list exited \(output.status)", level: .info)
                return .unavailable
            }
            return .models(Support.parseOllamaListTable(text), viaAPI: false)
        } catch {
            Logger.shared.log("Local AI Models: ollama list failed: \(error.localizedDescription)", level: .warning)
            return .unavailable
        }
    }

    // MARK: Hugging Face

    func scanHuggingFace() -> ScanOutcome {
        var outcome = ScanOutcome()
        var sharedRepoCount = 0
        var skippedSupportCount = 0
        var hasHubRepos = false
        // Links that point into a row make that row unsafe to remove.
        let links = symlinkIndex()
        func blockedDetail(_ path: String, default normal: String) -> String {
            guard let link = Support.linkPointingInto(path, links: links) else { return normal }
            return String(
                format: String(localized: "Linked from %@ · cannot be removed"),
                (link.path as NSString).abbreviatingWithTildeInPath
            )
        }

        if let root = hubRoot() {
            let names = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            let recognised = isRecognisedHub(root: root, names: names)
            for name in names where Support.isListableHubEntryName(name) {
                let path = root + "/" + name
                // lstat: a symlinked folder is never listed, so it can never
                // be removed through a link into somewhere else.
                guard let info = Support.entryInfo(atPath: path), info.type == .directory else { continue }

                if let repo = Support.parseHubRepoFolder(name) {
                    guard let inspection = Support.inspectHubRepo(atPath: path) else { continue }
                    if inspection.linksOutsideRepo {
                        sharedRepoCount += 1
                        continue
                    }
                    guard inspection.storedBytes > 0 else { continue }
                    hasHubRepos = true
                    outcome.items.append(CleanableItem(
                        name: repo.repoID,
                        path: path,
                        size: inspection.storedBytes,
                        category: .localAIModels,
                        isSelected: false,
                        lastModified: inspection.lastUsed,
                        detail: blockedDetail(path, default: repoDetail(kind: repo.kind, revisions: inspection.revisionCount)),
                        selectOnlyByHand: true
                    ))
                } else if recognised {
                    let size = Support.treeBytes(atPath: path, fileManager: fileManager)
                    guard size > 0 else { continue }
                    outcome.items.append(CleanableItem(
                        name: name,
                        path: path,
                        size: size,
                        category: .localAIModels,
                        isSelected: false,
                        lastModified: info.modified,
                        detail: blockedDetail(
                            path,
                            default: String(localized: "Non-standard folder in the Hugging Face cache · review before removing")
                        ),
                        selectOnlyByHand: true
                    ))
                }
            }
        }

        for root in Support.appSupportModelRoots(homePath: homePath) where isValidAppSupportRoot(root) {
            let rootName = (root as NSString).lastPathComponent
            let names = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for name in names where Support.isListableHubEntryName(name) {
                let path = root + "/" + name
                guard let info = Support.entryInfo(atPath: path), info.type == .file || info.type == .directory else { continue }
                // Only recognisable model data is offered; anything else in
                // these folders is left alone and counted in a note.
                guard Support.looksLikeModelData(atPath: path, fileManager: fileManager) else {
                    skippedSupportCount += 1
                    continue
                }
                let size = Support.treeBytes(atPath: path, fileManager: fileManager)
                guard size > 0 else { continue }
                outcome.items.append(CleanableItem(
                    name: "\(rootName)/\(name)",
                    path: path,
                    size: size,
                    category: .localAIModels,
                    isSelected: false,
                    lastModified: info.modified,
                    detail: blockedDetail(
                        path,
                        default: String(localized: "Model files in Application Support/huggingface · review before removing")
                    ),
                    selectOnlyByHand: true
                ))
            }
        }

        if sharedRepoCount > 0 {
            outcome.notes.append(String(
                format: String(localized: "%lld Hugging Face repo(s) keep their files in a shared store outside the repo folder and are not listed. Removing them would not free space."),
                Int64(sharedRepoCount)
            ))
        }
        if skippedSupportCount > 0 {
            outcome.notes.append(String(
                format: String(localized: "%lld item(s) in Application Support/huggingface were not listed because they do not look like model data."),
                Int64(skippedSupportCount)
            ))
        }
        if hasHubRepos {
            outcome.notes.append(String(localized: "Hugging Face last-used dates are approximate: the newest change among a repo's refs and snapshots."))
        }
        return outcome
    }

    private func repoDetail(kind: LocalAIModelsSupport.HubRepoKind, revisions: Int) -> String {
        let label: String
        switch kind {
        case .model: label = String(localized: "Hugging Face model")
        case .dataset: label = String(localized: "Hugging Face dataset")
        case .space: label = String(localized: "Hugging Face space")
        }
        return String(format: String(localized: "%@ · %lld revision(s)"), label, Int64(revisions))
    }

    /// Resolved hub cache root, or nil when it does not exist or sits
    /// somewhere a cache never lives (see `isPlausibleHubRoot`).
    private func hubRoot() -> String? {
        let configured = Support.hubCachePath(environment: context.environment, homePath: homePath)
        guard let canonical = Support.canonicalPath(configured),
              Support.entryInfo(atPath: canonical)?.type == .directory,
              Support.isPlausibleHubRoot(canonical, canonicalHome: homePath)
        else { return nil }
        return canonical
    }

    /// Non-standard folders are only offered inside something that is
    /// recognisably a Hugging Face hub cache, so a stray `HF_HOME` cannot
    /// make arbitrary folders removable.
    private func isRecognisedHub(root: String, names: [String]) -> Bool {
        if names.contains(where: { Support.parseHubRepoFolder($0) != nil }) { return true }
        return Support.entryInfo(atPath: root + "/CACHEDIR.TAG")?.type == .file
    }

    /// Every symlink in the places a link into a row can live: the hub root,
    /// every repo folder (listed or not: a repo that links into another repo
    /// would break if the target went), every non-standard hub folder, and the
    /// Application Support model folders. Links from outside these places, for
    /// example a project folder made by `hf download --local-dir`, are not
    /// found; that limit is stated in the review text and the docs.
    private func symlinkIndex() -> [Support.SymlinkRecord] {
        var records: [Support.SymlinkRecord] = []
        if let root = hubRoot() {
            let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            let recognised = isRecognisedHub(root: root, names: names)
            for name in names {
                let path = root + "/" + name
                guard let info = Support.entryInfo(atPath: path) else { continue }
                if info.type == .symlink {
                    if let target = Support.canonicalPath(path) {
                        records.append(Support.SymlinkRecord(path: path, target: target))
                    }
                } else if info.type == .directory, Support.isListableHubEntryName(name),
                          Support.parseHubRepoFolder(name) != nil || recognised {
                    records += Support.collectSymlinks(under: path, fileManager: fileManager)
                }
            }
        }
        for root in Support.appSupportModelRoots(homePath: homePath) where isValidAppSupportRoot(root) {
            records += Support.collectSymlinks(under: root, fileManager: fileManager)
        }
        return records
    }

    private func isValidAppSupportRoot(_ root: String) -> Bool {
        Support.entryInfo(atPath: root)?.type == .directory && Support.canonicalPath(root) == root
    }

    // MARK: - Removal

    func remove(_ item: CleanableItem) async -> RemovalOutcome {
        guard item.category == .localAIModels else {
            return RemovalOutcome(error: "Not a Local AI Models item: \(item.name)")
        }
        if let name = item.ollamaModelName {
            return await removeOllamaModel(name: name, expectedDigest: item.ollamaModelDigest, reportedSize: item.size)
        }
        return await removeHubEntry(path: item.path, reportedSize: item.size)
    }

    // MARK: Ollama

    /// Removes one model by name, after confirming its digest. When the API
    /// answered that check, `DELETE /api/delete` (this file's redirect-refusing
    /// client); only when the API is unreachable and `ollama list` answered,
    /// `ollama rm <name>`. Model blobs are shared between models, so files are
    /// never unlinked by hand; the freed amount is the listed size, an upper
    /// bound.
    func removeOllamaModel(name: String, expectedDigest: String?, reportedSize: Int64) async -> RemovalOutcome {
        guard Support.isValidOllamaModelName(name) else {
            return RemovalOutcome(error: "Refusing to remove Ollama model with an unsafe name: \(name)")
        }
        guard let endpoint = Support.ollamaEndpoint(environment: context.environment), endpoint.isLoopback else {
            return RemovalOutcome(error: "OLLAMA_HOST does not point to this Mac; Ollama models were not removed")
        }
        // A tag can be re-pulled after the scan; removal is by name, so make
        // sure the name still means the model the user reviewed.
        let viaAPI: Bool
        switch await confirmOllamaDigest(name: name, expected: expectedDigest) {
        case .skip(let message):
            Logger.shared.log(message, level: .warning)
            return RemovalOutcome(error: message)
        case .confirmed(let answeredByAPI):
            viaAPI = answeredByAPI
        }

        if viaAPI {
            // The server answered, so delete through our own request: the
            // `ollama` CLI follows 307/308 redirects, this one never does.
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/delete"))
            request.httpMethod = "DELETE"
            request.timeoutInterval = context.removeTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "name": name])
            do {
                let response = try await context.fetch(request)
                guard response.status == 200 else {
                    Logger.shared.log("DELETE /api/delete \(name) answered \(response.status)", level: .error)
                    return RemovalOutcome(error: "Ollama refused to remove \(name) (HTTP \(response.status))")
                }
            } catch {
                Logger.shared.log("DELETE /api/delete \(name) failed: \(error.localizedDescription)", level: .error)
                return RemovalOutcome(error: "Couldn't remove Ollama model \(name): \(error.localizedDescription)")
            }
        } else if let executable = firstExecutable(in: context.ollamaExecutableCandidates) {
            // The API did not answer but `ollama list` did: use the CLI.
            do {
                let output = try await context.runCommand(
                    URL(fileURLWithPath: executable), ["rm", name], context.removeTimeout, context.environment
                )
                guard output.status == 0 else {
                    let detail = firstLine(of: output.stderr) ?? firstLine(of: output.stdout) ?? "exit \(output.status)"
                    Logger.shared.log("ollama rm \(name) exited \(output.status): \(detail)", level: .error)
                    if detail.localizedCaseInsensitiveContains("connect") {
                        return RemovalOutcome(error: "Ollama isn't running — start it, then remove \(name) again")
                    }
                    return RemovalOutcome(error: "Couldn't remove Ollama model \(name): \(detail)")
                }
            } catch ApplicationUpdaterError.timedOut {
                Logger.shared.log("ollama rm \(name) timed out", level: .error)
                return RemovalOutcome(error: "ollama rm \(name) did not finish in time")
            } catch {
                Logger.shared.log("ollama rm \(name) failed: \(error.localizedDescription)", level: .error)
                return RemovalOutcome(error: "Couldn't run ollama rm \(name): \(error.localizedDescription)")
            }
        } else {
            return RemovalOutcome(error: "Ollama isn't running — start it, then remove \(name) again")
        }

        Logger.shared.log("Removed Ollama model \(name) (listed size \(reportedSize) bytes)", level: .info)
        return RemovalOutcome(freed: reportedSize, cleaned: true)
    }

    private enum DigestCheck {
        case confirmed(viaAPI: Bool)
        case skip(String)
    }

    /// Confirms the server (or `ollama list`) still reports the scanned
    /// digest for `name`, and says which of the two answered.
    private func confirmOllamaDigest(name: String, expected: String?) async -> DigestCheck {
        guard let expected, !expected.isEmpty else {
            return .skip("Skipped \(name): no digest was recorded at scan time, so it cannot be confirmed. Scan again")
        }
        switch await listOllamaModels() {
        case .models(let models, let viaAPI):
            guard let current = models.first(where: { $0.name == name }) else {
                return .skip("Skipped \(name): Ollama no longer lists it. Scan again")
            }
            guard Support.ollamaDigestsMatch(expected, current.digest) else {
                return .skip("Skipped \(name): the model changed since the scan (different digest). Scan again")
            }
            return .confirmed(viaAPI: viaAPI)
        case .unavailable, .remoteHost:
            return .skip("Skipped \(name): Ollama did not answer, so the model could not be confirmed")
        }
    }

    // MARK: Hugging Face

    private enum HubTarget {
        /// `models--org--name` (or datasets / spaces) directly inside the hub root.
        case repo(root: String, name: String, cliTarget: String?)
        /// Any other directory directly inside a recognised hub root.
        case hubFolder(root: String, name: String)
        /// A direct child of `Application Support/huggingface/{models,gguf_models}`.
        case appSupportEntry(root: String, name: String)

        var root: String {
            switch self {
            case .repo(let root, _, _), .hubFolder(let root, _), .appSupportEntry(let root, _): return root
            }
        }

        var name: String {
            switch self {
            case .repo(_, let name, _), .hubFolder(_, let name), .appSupportEntry(_, let name): return name
            }
        }

        var allowsRegularFile: Bool {
            if case .appSupportEntry = self { return true }
            return false
        }
    }

    /// Decide what a path is, from the current environment and disk, never
    /// from the scan. Returns nil unless it is a direct, non-symlinked child
    /// of a known model root that resolves to itself.
    private func classify(path: String) -> HubTarget? {
        guard Support.isNormalizedAbsolutePath(path) else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard Support.isListableHubEntryName(name) else { return nil }

        let target: HubTarget
        if let root = hubRoot(), parent == root {
            if let repo = Support.parseHubRepoFolder(name) {
                target = .repo(root: root, name: name, cliTarget: repo.cliTarget)
            } else {
                let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
                guard isRecognisedHub(root: root, names: names) else { return nil }
                target = .hubFolder(root: root, name: name)
            }
        } else if let root = Support.appSupportModelRoots(homePath: homePath).first(where: { $0 == parent }),
                  isValidAppSupportRoot(root) {
            target = .appSupportEntry(root: root, name: name)
        } else {
            return nil
        }

        // lstat, not stat: the entry itself must be a plain directory (or a
        // plain file under Application Support), and its fully resolved path
        // must be exactly root/name, so nothing in the chain is a symlink.
        guard let info = Support.entryInfo(atPath: path),
              info.type == .directory || (target.allowsRegularFile && info.type == .file),
              Support.canonicalPath(path) == target.root + "/" + target.name
        else { return nil }
        return target
    }

    func removeHubEntry(path: String, reportedSize: Int64) async -> RemovalOutcome {
        guard let target = classify(path: path) else {
            let message = "Refusing to remove \(path): not a direct, non-symlinked folder of a Hugging Face model location"
            Logger.shared.log(message, level: .warning)
            return RemovalOutcome(error: message)
        }

        if let message = removalBlock(for: target, path: path) {
            Logger.shared.log(message, level: .warning)
            return RemovalOutcome(error: message)
        }

        if case .repo(let root, _, let cliTarget) = target {
            if let cliTarget, let hf = await verifiedHFExecutable() {
                if await removeWithHFCLI(executable: hf, target: cliTarget, root: root), Support.entryInfo(atPath: path) == nil {
                    Logger.shared.log("Removed Hugging Face repo \(cliTarget) with hf cache rm", level: .info)
                    return RemovalOutcome(freed: reportedSize, cleaned: true)
                }
                Logger.shared.log("hf cache rm \(cliTarget) did not remove the repo; deleting the validated folder instead", level: .warning)
            }
        }

        // Re-validate immediately before unlinking: the CLI attempt above can
        // take a while and the folder may have been swapped for a link.
        // Full re-check, not just the path: a failed or timed-out CLI may have
        // left the folder half deleted, linked, or newly linked-to.
        guard let current = classify(path: path) else {
            let message = "Aborting removal: \(path) changed between validation and delete"
            Logger.shared.log(message, level: .warning)
            return RemovalOutcome(error: message)
        }
        if let message = removalBlock(for: current, path: path) {
            Logger.shared.log(message, level: .warning)
            return RemovalOutcome(error: message)
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            let message = "\(target.name) at \(path): \(error.localizedDescription)"
            Logger.shared.log("Clean failed: \(message)", level: .error)
            return RemovalOutcome(error: message)
        }
        Logger.shared.log("Removed \(path) (\(reportedSize) bytes)", level: .info)
        return RemovalOutcome(freed: reportedSize, cleaned: true)
    }

    /// Why `path` must not be removed right now, or nil. Runs before the CLI
    /// and again before the fallback delete.
    private func removalBlock(for target: HubTarget, path: String) -> String? {
        // Same rule as the generic route (issue #142): a cache placed in iCloud
        // Drive or a file provider (HF_HOME, HF_HUB_CACHE) is not deleted,
        // through the hf CLI or otherwise.
        if ProviderPaths.isProviderOwned(path, homeDirectory: context.homeDirectory) {
            return "Skipped \(target.name): it is in iCloud Drive or another cloud-synced folder"
        }
        if case .repo(_, let name, _) = target {
            guard let inspection = Support.inspectHubRepo(atPath: path) else {
                return "Couldn't read \(name)"
            }
            if inspection.linksOutsideRepo {
                return "Skipped \(name): its files live in a shared store outside the repo folder, so removing the folder would not free space"
            }
        }
        if let canonical = Support.canonicalPath(path),
           let link = Support.linkPointingInto(canonical, links: symlinkIndex()) {
            return "Skipped \(target.name): \(link.path) links into it, so removing it would break that link"
        }
        return nil
    }

    /// The `hf` CLI is used only when this install documents the flags we
    /// pass: `hf cache rm --help` must exit 0 and mention `--cache-dir` and
    /// `--yes`. Older releases (`huggingface-cli delete-cache`) are
    /// interactive and are never driven.
    private func verifiedHFExecutable() async -> URL? {
        guard let path = firstExecutable(in: context.hfExecutableCandidates) else { return nil }
        let url = URL(fileURLWithPath: path)
        do {
            let output = try await context.runCommand(url, ["cache", "rm", "--help"], context.listTimeout, context.environment)
            let help = String(data: output.stdout, encoding: .utf8) ?? ""
            guard output.status == 0, help.contains("--cache-dir"), help.contains("--yes") else { return nil }
            return url
        } catch {
            Logger.shared.log("hf cache rm --help failed: \(error.localizedDescription)", level: .info)
            return nil
        }
    }

    private func removeWithHFCLI(executable: URL, target: String, root: String) async -> Bool {
        do {
            let output = try await context.runCommand(
                executable,
                ["cache", "rm", target, "--cache-dir", root, "--yes"],
                context.removeTimeout,
                context.environment
            )
            if output.status != 0 {
                Logger.shared.log("hf cache rm \(target) exited \(output.status): \(firstLine(of: output.stderr) ?? "")", level: .warning)
            }
            return output.status == 0
        } catch {
            Logger.shared.log("hf cache rm \(target) failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    // MARK: - Helpers

    private func firstExecutable(in candidates: [String]) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func firstLine(of data: Data) -> String? {
        String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
