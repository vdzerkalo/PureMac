import Foundation

actor CleaningEngine {
    private let fileManager = FileManager.default
    /// Always symlink-resolved so allow-listed roots agree with ScanEngine and
    /// XcodeBuildMCPDerivedDataSupport path checks on symlinked homes.
    private let homeDirectory: URL
    private let binaryThinner = BinaryThinner()
    /// Reports whether an AI agent app is running. Injected by tests; the
    /// default inspects the real process list.
    private let isAIAgentOwnerRunning: AIAgentDataSupport.OwnerRunningCheck
    /// Moves a URL to the Trash and returns where it went. Used by every Move
    /// to Trash route (XcodeBuildMCP DerivedData, AI agent data). Injected by
    /// tests so they never touch the real Trash.
    typealias TrashOperation = (URL) throws -> URL?
    private let trashOperation: TrashOperation

    static let systemTrash: TrashOperation = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Read at clean time so the re-check before a worktree removal uses the
    /// settings in force now, not those of the scan.
    private let worktreeSettings: @Sendable () -> GitWorktreeSettings
    /// Tests point this at a fake CLI script so no real docker ever runs;
    /// nil in the app, which searches DockerSupport.candidateBinaryPaths.
    private let dockerBinaryPath: String?
    /// Search directories, process list and timeouts for the developer tool
    /// caches (uv, go, Gradle). Tests inject fakes; the app uses `.live`.
    private let devTools: DevToolCacheEnvironment
    /// Ollama API and CLI, `hf` and the model folders. Tests inject fakes.
    private let localAIModels: LocalAIModels

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        dockerBinaryPath: String? = nil,
        worktreeSettings: @escaping @Sendable () -> GitWorktreeSettings = { GitWorktreeSettings.current() },
        devToolEnvironment: DevToolCacheEnvironment = .live,
        localAIModels: LocalAIModels? = nil,
        isAIAgentOwnerRunning: AIAgentDataSupport.OwnerRunningCheck? = nil,
        trashOperation: @escaping TrashOperation = CleaningEngine.systemTrash
    ) {
        let canonicalHome = XcodeBuildMCPDerivedDataSupport.canonicalHomeDirectory(homeDirectory)
        self.homeDirectory = canonicalHome
        self.dockerBinaryPath = dockerBinaryPath
        self.worktreeSettings = worktreeSettings
        self.devTools = devToolEnvironment
        self.localAIModels = localAIModels ?? LocalAIModels(context: .live(homeDirectory: canonicalHome))
        self.isAIAgentOwnerRunning = isAIAgentOwnerRunning
            ?? AIAgentDataSupport.liveOwnerRunningCheck(homeDirectory: homeDirectory)
        self.trashOperation = trashOperation
    }

    struct CleaningResult {
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        /// Destination paths returned by FileManager.trashItem. Keeping these
        /// lets callers and tests distinguish recoverable Trash moves from
        /// irreversible removals.
        var trashedPaths: Set<String> = []
        // Items that user-level FileManager.removeItem refused with EACCES /
        // EPERM. These are root-owned and need an admin-privileged second
        // pass via cleanWithAdminPrivileges(items:).
        var requiresAdmin: [CleanableItem] = []
        // Paths skipped because they are SIP-protected or immutable (see
        // FileProtection). Deleting these fails even as root, so they are
        // recorded here — not in errors — and must never trigger the
        // "Couldn't clean everything" alert.
        var protectedPaths: Set<String> = []
        var skippedProtected: Int { protectedPaths.count }
        /// Things worth telling the user about a clean that still counted as
        /// done, e.g. a merged branch git refused to delete.
        var notes: [String] = []
        // Paths deliberately left alone because the owning tool is busy (uv
        // cache locked, Gradle running). The reason is in `errors`; unlike a
        // survivor, Full Disk Access cannot fix these, so they must not raise
        // the Grant Access prompt.
        var skippedPaths: Set<String> = []
    }

    // MARK: - Public API

    func cleanItems(_ selectedItems: [CleanableItem], progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        var result = CleaningResult()
        // Docker prune rows run in DockerSupport.PruneAction.cleanOrder, not
        // in the order they were selected.
        let items = DockerSupport.orderedForCleaning(selectedItems)
        let total = items.count
        let exclusions = CleanupExclusions.paths()

        for (index, item) in items.enumerated() {
            let progress = Double(index + 1) / Double(total)
            defer { progressHandler(progress) }
            if CleanupExclusions.excludes(item.path, paths: exclusions) {
                result.errors.append("Excluded from cleanup: \(item.name)")
                continue
            }

            if item.category == .aiApps, !isSupportedAIAppPath(item.path) {
                result.errors.append("Unsupported AI app cleanup path: \(item.path)")
                continue
            }

            if item.category == .localAIModels {
                // Models are removed only through LocalAIModels: the Ollama API
                // (or `ollama rm` when the API is unreachable), and `hf cache rm` or one validated folder delete
                // for Hugging Face. This never reaches the generic allow-list
                // below, and never the admin pass.
                let outcome = await localAIModels.remove(item)
                result.freedSpace += outcome.freed
                if outcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = outcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if item.category == .aiAgentData {
                // Dedicated route: exact allowlisted paths only, Move to Trash
                // only, never while the owning app runs. The generic allowlist
                // (which contains all of Application Support) is not consulted.
                let outcome = trashAIAgentDataItem(item)
                if outcome.alreadyGone { result.cleanedPaths.insert(item.path) }
                if outcome.cleaned {
                    result.freedSpace += item.size
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                    if let trashed = outcome.trashedPath { result.trashedPaths.insert(trashed) }
                }
                if let error = outcome.error { result.errors.append(error) }
                continue
            }

            if item.category == .purgeableSpace {
                let purged = await purgePurgeableSpace()
                result.freedSpace += purged
                if purged > 0 { result.itemsCleaned += 1 }
                // Purgeable space is a one-shot reclaim action, not a file
                // unlink. Mark it handled so it isn't later mistaken for an
                // item that "couldn't be removed" (the purge ran regardless of
                // how much APFS chose to release). See issue #112.
                result.cleanedPaths.insert(item.path)
                continue
            }

            if item.category == .universalBinaries {
                // Thinning is a lipo rewrite plus re-sign, not a file unlink,
                // so it bypasses the delete path entirely. The item path is
                // the app bundle; the per-binary work list is re-derived here
                // so a stale scan can't strip slices that no longer exist.
                let thinOutcome = await thinUniversalBinaryItem(item)
                result.freedSpace += thinOutcome.freed
                if thinOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = thinOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if item.category == .languageFiles {
                // Localizations are sealed into the bundle's CodeResources; a
                // plain unlink would break the app's code signature, so the
                // folder is removed through BinaryThinner's staged re-sign
                // flow instead of the delete path.
                let lprojOutcome = await removeLanguageFileItem(item)
                result.freedSpace += lprojOutcome.freed
                if lprojOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = lprojOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if item.category == .devToolCaches {
                // Developer tool caches never take the generic unlink path:
                // each root is validated by exact match, and tools that manage
                // their own cache (uv, go) are cleaned through their CLI.
                let outcome = await cleanDevToolCache(item)
                result.freedSpace += outcome.freed
                if outcome.removed { result.itemsCleaned += 1 }
                if outcome.handled { result.cleanedPaths.insert(item.path) }
                if outcome.skipped { result.skippedPaths.insert(item.path) }
                if let error = outcome.error { result.errors.append(error) }
                continue
            }

            if item.category == .gitWorktrees {
                // Worktrees are removed through git, never unlinked or moved
                // to the Trash: that would leave git's metadata pointing at a
                // missing folder and keep the bytes on the same volume.
                // Artifact rows (build folders inside a worktree that stays)
                // have their own validated route.
                let outcome = item.worktreeArtifacts != nil
                    ? await removeWorktreeArtifacts(item)
                    : await removeGitWorktree(item)
                result.freedSpace += outcome.freed
                if outcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = outcome.error {
                    result.errors.append(error)
                }
                if let note = outcome.note {
                    result.notes.append(note)
                }
                continue
            }

            if let action = item.dockerPruneAction {
                // Virtual Docker Cache rows reclaim space inside the
                // Docker/OrbStack VM through their own prune command — there
                // is no file to unlink.
                // Volumes are removed by the names recorded at scan time,
                // never pruned (see removeDockerVolumes).
                let pruneOutcome: (freed: Int64, error: String?)
                if action == .unusedVolumes {
                    pruneOutcome = await removeDockerVolumes(DockerSupport.volumeEntries(forPath: item.path))
                } else {
                    pruneOutcome = await pruneDocker(action)
                }
                result.freedSpace += pruneOutcome.freed
                if pruneOutcome.error == nil {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = pruneOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            if let runtimeID = item.simctlRuntimeIdentifier {
                // Simulator runtimes live in CoreSimulator's secure storage;
                // deleting the mount path by hand leaves orphaned disk images.
                // Always go through `xcrun simctl runtime delete`.
                let deleteOutcome = await deleteSimulatorRuntime(identifier: runtimeID, reportedSize: item.size)
                result.freedSpace += deleteOutcome.freed
                if deleteOutcome.cleaned {
                    result.itemsCleaned += 1
                    result.cleanedPaths.insert(item.path)
                }
                if let error = deleteOutcome.error {
                    result.errors.append(error)
                }
                continue
            }

            do {
                let itemURL = URL(fileURLWithPath: item.path)
                guard !hasUnexpectedSymlink(in: item.path) else {
                    let msg = "Skipped symlink or unsafe path: \(item.path)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }
                guard fileManager.fileExists(atPath: item.path) else {
                    result.cleanedPaths.insert(item.path)
                    continue
                }
                let resolvedURL = itemURL.resolvingSymlinksInPath()
                let resolved = resolvedURL.path

                // Large files surfaced by scanLargeFiles are per-file items
                // under Downloads/Documents/Desktop; those get a narrower check
                // instead of the whole-subtree allow-list.
                // languageFiles never reaches here — it is handled above via
                // the staged re-sign flow, not the delete path.
                let pathAccepted = isSafeToDelete(item: item, resolvedPath: resolved)
                guard pathAccepted else {
                    let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                // Narrow the TOCTOU window: re-resolve right before the delete
                // and require the resolved path to still match. Any concurrent
                // swap between check and delete aborts the operation.
                let reResolved = itemURL.resolvingSymlinksInPath().path
                guard reResolved == resolved, !hasUnexpectedSymlink(in: item.path) else {
                    let msg = "Aborting delete: path resolution changed between check and unlink for \(item.path)"
                    Logger.shared.log(msg, level: .warning)
                    result.errors.append(msg)
                    continue
                }

                let isManagedDerivedData = XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
                    item.path,
                    homeDirectory: homeDirectory
                ) || XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
                    resolved,
                    homeDirectory: homeDirectory
                )
                if isManagedDerivedData {
                    // The legacy shared root predates XcodeBuildMCP's
                    // per-workspace lock, so only workspace DerivedData waits
                    // for the lock before moving to the Trash.
                    var lifecycleLock: XcodeBuildMCPDerivedDataSupport.LifecycleLock?
                    if XcodeBuildMCPDerivedDataSupport.workspaceKey(
                        forManagedDerivedDataPath: resolved,
                        homeDirectory: homeDirectory
                    ) != nil {
                        guard let acquired = XcodeBuildMCPDerivedDataSupport.acquireLifecycleLock(
                            forManagedDerivedDataPath: resolved,
                            homeDirectory: homeDirectory,
                            fileManager: fileManager
                        ) else {
                            let detail = "Skipped XcodeBuildMCP DerivedData: lifecycle lock is unavailable: \(item.path)"
                            Logger.shared.log(detail, level: .warning)
                            result.errors.append(detail)
                            continue
                        }
                        lifecycleLock = acquired
                    }
                    defer {
                        if let lifecycleLock {
                            XcodeBuildMCPDerivedDataSupport.releaseLifecycleLock(
                                lifecycleLock,
                                fileManager: fileManager
                            )
                        }
                    }
                    // PureMac's safety contract is Trash-only for recoverable
                    // cleanup. XcodeBuildMCP DerivedData must not be unlinked.
                    if let trashedPath = try trashOperation(resolvedURL)?.path {
                        result.trashedPaths.insert(trashedPath)
                    }
                } else {
                    try fileManager.removeItem(at: itemURL)
                }
                result.freedSpace += item.size
                result.itemsCleaned += 1
                result.cleanedPaths.insert(item.path)
            } catch {
                let nsError = error as NSError
                let isPermissionDenied =
                    (nsError.domain == NSCocoaErrorDomain &&
                        (nsError.code == NSFileWriteNoPermissionError ||
                         nsError.code == NSFileReadNoPermissionError)) ||
                    (nsError.domain == NSPOSIXErrorDomain &&
                        (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)))
                if isPermissionDenied {
                    if item.category == .aiApps {
                        let detail = "AI app cleanup requires access as the current user: \(item.path)"
                        result.errors.append(detail)
                        Logger.shared.log(detail, level: .warning)
                        continue
                    }
                    if XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
                        item.path,
                        homeDirectory: homeDirectory
                    ) {
                        let detail = "Refusing administrator escalation for XcodeBuildMCP DerivedData: \(item.path)"
                        result.errors.append(detail)
                        Logger.shared.log(detail, level: .warning)
                        continue
                    }
                    // SIP-protected/immutable entries fail even as root, so
                    // escalating them just wastes an auth prompt and produces
                    // a bogus "survived admin removal" error. Record and move on.
                    if FileProtection.isProtectedFromDeletion(path: item.path) {
                        result.protectedPaths.insert(item.path)
                        Logger.shared.log("Skipping SIP-protected path: \(item.path)", level: .info)
                        continue
                    }
                    // Defer to the admin pass — these are typically root-owned
                    // system caches that the user-level process can't unlink.
                    result.requiresAdmin.append(item)
                    Logger.shared.log("Deferring to admin pass: \(item.path)", level: .info)
                } else {
                    let detail = "\(item.name) at \(item.path): \(error.localizedDescription)"
                    result.errors.append(detail)
                    Logger.shared.log("Clean failed: \(detail)", level: .error)
                }
            }
        }

        return result
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        let selectedItems = result.items.filter { $0.isSelected }
        return await cleanItems(selectedItems, progressHandler: progressHandler)
    }

    /// Re-runs the deletion of the supplied items as root via NSAppleScript's
    /// "with administrator privileges" clause. Triggers exactly one auth
    /// prompt for the whole batch (macOS caches the credential for ~5 min).
    ///
    /// Every path is re-validated against the same allow-list as the user-
    /// level pass (isSafeToDelete / isExplicitSingleFileDeletable) before it
    /// gets handed off to /bin/rm. Paths are passed via a NUL-separated
    /// temp file consumed by xargs -0, so no shell-quoting pitfalls.
    func cleanWithAdminPrivileges(items: [CleanableItem]) async -> CleaningResult {
        var result = CleaningResult()

        Logger.shared.log("Admin pass starting with \(items.count) item(s)", level: .info)

        // Re-validate. Don't trust the caller — anything not on the allow-list
        // refuses to escalate.
        let exclusions = CleanupExclusions.paths()
        let validated: [(item: CleanableItem, resolved: String)] = items.compactMap { item in
            guard item.category != .localAIModels else {
                result.errors.append("Administrator cleanup is unavailable for local AI models: \(item.name)")
                return nil
            }
            guard item.category != .aiApps, item.category != .aiAgentData else {
                result.errors.append("Administrator cleanup is unavailable for AI app data: \(item.name)")
                return nil
            }
            guard item.category != .devToolCaches else {
                result.errors.append("Administrator cleanup is unavailable for developer tool caches: \(item.name)")
                return nil
            }
            guard !CleanupExclusions.excludes(item.path, paths: exclusions) else { return nil }
            guard !hasUnexpectedSymlink(in: item.path) else {
                Logger.shared.log("Refusing admin escalation for symlinked path: \(item.path)", level: .warning)
                return nil
            }
            let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
            let isManaged = XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
                item.path,
                homeDirectory: homeDirectory
            ) || XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
                resolved,
                homeDirectory: homeDirectory
            )
            guard !isManaged else {
                Logger.shared.log(
                    "Refusing administrator escalation for XcodeBuildMCP DerivedData: \(item.path)",
                    level: .warning
                )
                return nil
            }
            // languageFiles is deliberately absent: an admin rm -rf of an
            // .lproj would break the bundle's signature seal with no re-sign,
            // so those items never escalate.
            let accepted = isSafeToDelete(
                item: item,
                resolvedPath: resolved,
                includeUninstallPaths: true
            )
            if !accepted {
                Logger.shared.log("Refusing admin escalation for unsafe path: \(item.path)", level: .warning)
            }
            return accepted ? (item, resolved) : nil
        }
        guard !validated.isEmpty else {
            Logger.shared.log("Admin pass: no items survived validation", level: .warning)
            return result
        }

        // Stage paths NUL-separated so newlines/spaces in paths don't matter.
        let staged = validated.map(\.resolved).joined(separator: "\u{0}")
        guard let payload = staged.data(using: .utf8) else { return result }

        // Live daemon logs (e.g. /private/var/log/wifi.log) are recreated by
        // their writer the instant root rm unlinks them. A bare re-stat then
        // misreads the fresh file as "survived admin removal" and raises a
        // bogus "Couldn't clean everything" alert. Capture each path's inode
        // before the delete so the survivor check can tell a recreated file
        // from an untouched one.
        var preDeleteInodes: [String: UInt64] = [:]
        for (_, resolved) in validated {
            if let attrs = try? fileManager.attributesOfItem(atPath: resolved),
               let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value {
                preDeleteInodes[resolved] = inode
            }
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("puremac-rm-\(UUID().uuidString)")
        do {
            try payload.write(to: tempFile, options: [.atomic])
        } catch {
            Logger.shared.log("Couldn't stage admin path list: \(error.localizedDescription)", level: .error)
            return result
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let quotedTempPath = shellSingleQuoted(tempFile.path)
        let script = """
        do shell script "/usr/bin/xargs -0 /bin/rm -rf -- < \(quotedTempPath)" with administrator privileges
        """

        let runError: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                appleScript?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(returning: "\(errorInfo)")
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        if let runError, runError.contains("-128") {
            return result
        }
        if let runError {
            Logger.shared.log("Admin clean incomplete: \(runError)", level: .error)
        }

        // Verify which items actually disappeared. xargs may have reported a
        // partial failure even when the AppleScript exited cleanly, so we
        // re-stat every path rather than trust the script's exit status.
        for (item, resolved) in validated {
            if !FileManager.default.fileExists(atPath: resolved) {
                result.cleanedPaths.insert(item.path)
                result.itemsCleaned += 1
                result.freedSpace += item.size
            } else if FileProtection.isProtectedFromDeletion(path: resolved) {
                // SIP-protected survivors are expected — root rm can't touch
                // them either. Record quietly instead of raising an error.
                result.protectedPaths.insert(item.path)
                Logger.shared.log("Admin pass skipped SIP-protected path: \(item.path)", level: .info)
            } else if let preInode = preDeleteInodes[resolved],
                      let nowInode = ((try? fileManager.attributesOfItem(atPath: resolved))?[.systemFileNumber] as? NSNumber)?.uint64Value,
                      nowInode != preInode {
                // Different inode: the original WAS deleted and the owning
                // daemon immediately recreated the file. The old bytes are
                // gone, so count it as cleaned rather than a survivor.
                result.cleanedPaths.insert(item.path)
                result.itemsCleaned += 1
                result.freedSpace += item.size
                Logger.shared.log("Deleted and recreated by its daemon (live log): \(item.path)", level: .info)
            } else {
                let detail = "\(item.name) at \(item.path) survived admin removal"
                result.errors.append(detail)
                Logger.shared.log("Admin pass survivor: \(detail)", level: .error)
            }
        }
        Logger.shared.log("Admin pass complete: \(result.itemsCleaned) deleted, \(result.errors.count) survived, \(result.skippedProtected) protected", level: .info)
        return result
    }

    // MARK: - AI agent data

    /// Moves one review-only AI agent data item to the Trash. Validates right
    /// before the move (shape, symlinks, real path, rule requirements, owning
    /// app not running), using the process list as it is now, not as it was at
    /// scan time. The remaining window between that check and the move is a
    /// same-user race; see docs/AI-AGENT-DATA.md.
    private func trashAIAgentDataItem(
        _ item: CleanableItem
    ) -> (cleaned: Bool, alreadyGone: Bool, trashedPath: String?, error: String?) {
        func refuse(
            _ refusal: AIAgentDataSupport.Refusal
        ) -> (cleaned: Bool, alreadyGone: Bool, trashedPath: String?, error: String?) {
            // Gone since the scan: nothing to remove, nothing to report.
            if refusal == .missing { return (false, true, nil, nil) }
            let msg: String
            if case .ownerRunning(let owner) = refusal {
                msg = "Skipped AI agent data: \(owner.displayName) is running: \(item.path)"
            } else {
                msg = "Skipped AI agent data: \(refusal): \(item.path)"
            }
            Logger.shared.log(msg, level: .warning)
            return (false, false, nil, msg)
        }

        let validation = AIAgentDataSupport.validateForRemoval(
            path: item.path,
            homeDirectory: homeDirectory,
            isOwnerRunning: isAIAgentOwnerRunning,
            fileManager: fileManager
        )
        let validated: AIAgentDataSupport.Validated
        switch validation {
        case .failure(let refusal): return refuse(refusal)
        case .success(let value): validated = value
        }

        do {
            let resulting = try trashOperation(validated.url)
            return (true, false, resulting?.path, nil)
        } catch {
            let detail = "\(item.name) at \(item.path): \(error.localizedDescription)"
            Logger.shared.log("Clean failed: \(detail)", level: .error)
            return (false, false, nil, detail)
        }
    }

    // MARK: - Docker

    /// Result of one docker invocation: it ran (any exit status) or it could
    /// not, with the message the review sheet shows.
    private enum DockerRun {
        case finished(status: Int32, stdout: String, stderr: String)
        case failed(String)
    }

    /// Runs the docker CLI with a timeout. BrewProcessRunner drains both
    /// pipes while waiting and kills the process on timeout, so a wedged
    /// daemon can't hang the clean forever. `keepOutputTail` is for prunes:
    /// they list every deleted object, can print far more than the default
    /// 4 MB cap, and put the "Total reclaimed space" summary last.
    private func runDocker(
        _ arguments: [String],
        label: String,
        timeout: TimeInterval,
        keepOutputTail: Bool = false
    ) async -> DockerRun {
        guard let dockerBin = dockerBinaryPath ?? DockerSupport.locateBinary(homeDirectory: homeDirectory.path) else {
            return .failed("Docker CLI not found — install Docker Desktop or OrbStack")
        }
        do {
            let result = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: dockerBin),
                arguments: arguments,
                timeout: timeout,
                keepOutputTail: keepOutputTail
            )
            return .finished(
                status: result.status,
                stdout: String(data: result.stdout, encoding: .utf8) ?? "",
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        } catch is CancellationError {
            // The process is terminated, but the daemon may have finished part
            // of the work: not a success, so the row is not marked cleaned.
            Logger.shared.log("\(label) was cancelled", level: .warning)
            return .failed("\(label) was cancelled before it finished — some objects may already be removed; scan again")
        } catch ApplicationUpdaterError.timedOut {
            Logger.shared.log("\(label) timed out after \(Int(timeout))s", level: .error)
            return .failed("\(label) did not finish in time — check Docker Desktop or OrbStack, then clean again")
        } catch ApplicationUpdaterError.outputLimitExceeded {
            Logger.shared.log("\(label) printed more output than PureMac can read", level: .error)
            return .failed("\(label) printed more output than PureMac can read — run it in Terminal to see the result")
        } catch {
            Logger.shared.log("\(label) failed to launch: \(error.localizedDescription)", level: .error)
            return .failed("Couldn't run \(label): \(error.localizedDescription)")
        }
    }

    /// Maps a non-zero exit to a row error. The stderr is logged first, so
    /// the friendly "isn't running" text never hides what Docker said.
    private func dockerFailure(status: Int32, stderr: String, label: String) -> String {
        Logger.shared.log("\(label) exited \(status): \(stderr)", level: .error)
        if DockerSupport.isDaemonUnavailable(stderr: stderr) {
            return "Docker isn't running — start Docker Desktop or OrbStack, then clean again"
        }
        return "\(label) failed (exit \(status))"
    }

    /// Runs the prune behind one Docker Cache row (see
    /// DockerSupport.PruneAction) and reports the bytes Docker says it
    /// reclaimed. Each command prints only what it removed itself, so the
    /// freed bytes of several rows add up without overlap. Running
    /// containers and the images they use are never removed by any of these
    /// commands. With a VM-based runtime (Docker Desktop, OrbStack) the junk
    /// lives inside the VM disk, unreachable by any file unlink from the
    /// host. Returns a friendly error when no CLI is installed or the daemon
    /// is not running — common with OrbStack, which only runs on demand.
    /// Volumes are not pruned: see removeDockerVolumes.
    func pruneDocker(_ action: DockerSupport.PruneAction) async -> (freed: Int64, error: String?) {
        guard action != .unusedVolumes else {
            return (0, "Volumes are removed by name only — scan again")
        }
        let label = action.commandLine
        switch await runDocker(action.arguments, label: label, timeout: DockerSupport.pruneTimeout, keepOutputTail: true) {
        case .failed(let message):
            return (0, message)
        case .finished(let status, let stdout, let stderr):
            guard status == 0 else {
                return (0, dockerFailure(status: status, stderr: stderr, label: label))
            }
            let bytes = DockerSupport.parseReclaimedSpace(stdout) ?? 0
            Logger.shared.log("\(label) reclaimed \(bytes) bytes", level: .info)
            return (bytes, nil)
        }
    }

    /// Removes the volumes a volumes row recorded at scan time, and nothing
    /// else. `docker volume prune -a` would also erase volumes freed by a
    /// container prune in the same run; this removes only volumes that were
    /// unused when the user saw the list.
    ///
    /// 1. Re-check, right before acting, which recorded volumes are still
    ///    unused (`volume ls --filter dangling=true`). A volume that vanished
    ///    or became in use is skipped silently.
    /// 2. `docker volume rm <names>` WITHOUT `-f`: the daemon itself refuses
    ///    a volume that is in use, so a race after step 1 cannot erase one.
    ///    Per-volume failures are reported; the rest are still removed.
    ///
    /// Freed bytes are the scan-time sizes of the volumes Docker printed as
    /// removed (`volume rm` prints names, not sizes).
    func removeDockerVolumes(_ recorded: [DockerSupport.VolumeEntry]) async -> (freed: Int64, error: String?) {
        guard !recorded.isEmpty else {
            return (0, "No unused volumes were recorded for this row — scan again")
        }
        let listLabel = "docker volume ls"
        let listing = await runDocker(DockerSupport.unusedVolumeNamesArguments, label: listLabel, timeout: DockerSupport.danglingLookupTimeout)
        let unusedNow: Set<String>
        switch listing {
        case .failed(let message):
            return (0, message)
        case .finished(let status, let stdout, let stderr):
            guard status == 0 else {
                return (0, dockerFailure(status: status, stderr: stderr, label: listLabel))
            }
            unusedNow = Set(DockerSupport.parseVolumeNames(stdout))
        }
        let targets = recorded.filter { unusedNow.contains($0.name) }
        if targets.count < recorded.count {
            Logger.shared.log("docker volume rm: \(recorded.count - targets.count) recorded volume(s) no longer exist or are in use now, skipped", level: .info)
        }
        guard !targets.isEmpty else { return (0, nil) }

        let label = "docker volume rm"
        let arguments = DockerSupport.PruneAction.unusedVolumes.arguments + targets.map(\.name)
        switch await runDocker(arguments, label: label, timeout: DockerSupport.pruneTimeout, keepOutputTail: true) {
        case .failed(let message):
            return (0, message)
        case .finished(let status, let stdout, let stderr):
            let outcome = DockerSupport.parseVolumeRemoval(stdout: stdout, stderr: stderr, requested: targets)
            if status != 0, outcome.removed.isEmpty, outcome.problems.isEmpty, outcome.vanished == 0 {
                return (0, dockerFailure(status: status, stderr: stderr, label: label))
            }
            if status != 0, outcome.removed.isEmpty, DockerSupport.isDaemonUnavailable(stderr: stderr) {
                return (0, dockerFailure(status: status, stderr: stderr, label: label))
            }
            let freed = outcome.removed.reduce(Int64(0)) { $0 + $1.bytes }
            if outcome.vanished > 0 {
                Logger.shared.log("\(label): \(outcome.vanished) volume(s) vanished before removal, skipped", level: .info)
            }
            Logger.shared.log("\(label) removed \(outcome.removed.count) of \(targets.count) volume(s), \(freed) bytes (scan-time sizes)", level: .info)
            for problem in outcome.problems { Logger.shared.log(problem, level: .warning) }
            return (freed, outcome.problems.isEmpty ? nil : outcome.problems.joined(separator: "; "))
        }
    }

    // MARK: - Git Worktrees

    /// Re-checks a worktree right before removing it (status, lock, in-use
    /// and unpushed work can all change after the scan), then runs
    /// `git worktree remove` without --force. Protected or orphan verdicts,
    /// and anything git itself refuses, leave the worktree untouched.
    ///
    /// A row scanned as a prunable orphan (folder already gone) gets
    /// `git worktree prune` instead, and only while it is still one; a row
    /// scanned as anything else is never pruned. With the "delete merged
    /// branch" setting on, a worktree whose fresh verdict is Safe to delete
    /// also loses its branch via `git branch -d`; a refusal is returned as
    /// a note and does not undo the removal.
    func removeGitWorktree(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?, note: String?) {
        guard let report = item.gitWorktree, let repository = report.repositoryPath else {
            return (0, false, "Not a git worktree PureMac can remove: \(item.name)", nil)
        }
        guard let gitPath = GitWorktreeScanner.locateGit() else {
            return (0, false, "git not found — install Homebrew git or the Xcode command-line tools", nil)
        }
        let settings = worktreeSettings()
        var scanner = GitWorktreeScanner(homeDirectory: homeDirectory.path, gitPath: gitPath)
        scanner.inactiveDays = settings.inactiveDays
        scanner.baseBranchOverride = settings.baseBranch
        guard let fresh = await scanner.reinspect(path: item.path, repository: repository) else {
            return (0, false, "\(item.name) is no longer a worktree of \(repository)", nil)
        }
        if report.verdict.isPrunableOrphan || fresh.verdict.isPrunableOrphan {
            guard report.verdict.isPrunableOrphan, fresh.verdict.isPrunableOrphan else {
                Logger.shared.log("Skipped worktree \(item.path): its state changed since the scan", level: .warning)
                return (0, false, "\(item.name): the folder appeared or disappeared since the scan; rescan first", nil)
            }
            if let error = await scanner.prune(path: item.path, repository: repository) {
                Logger.shared.log("git worktree prune for \(item.path) refused: \(error)", level: .warning)
                return (0, false, "\(item.name): \(error)", nil)
            }
            Logger.shared.log("Pruned missing worktree \(item.path) in \(repository)", level: .info)
            return (0, true, nil, nil)
        }
        // Worse than what the user was shown (a new reason, or a more severe
        // status) means the worktree changed since the scan: the choice was
        // made on stale information, so nothing is removed.
        if fresh.verdict.isWorse(than: report.verdict) {
            let added = fresh.verdict.reasonsAdded(since: report.verdict)
            let why = (added.isEmpty ? fresh.verdict.reasons : added).map(\.localizedDescription).joined(separator: ", ")
            Logger.shared.log("Skipped worktree \(item.path): worse than at the scan (\(fresh.verdict.status.rawValue): \(why))", level: .warning)
            return (0, false, "\(item.name): changed since the scan (\(fresh.verdict.status.label): \(why)); rescan first", nil)
        }
        guard !fresh.verdict.status.blocksSelection else {
            let why = fresh.verdict.reasons.map(\.localizedDescription).joined(separator: ", ")
            Logger.shared.log("Skipped worktree \(item.path): \(fresh.verdict.status.rawValue) (\(why))", level: .warning)
            return (0, false, "\(fresh.verdict.status.label): \(why) — \(item.name)", nil)
        }
        if let error = await scanner.remove(path: item.path, repository: repository) {
            Logger.shared.log("git worktree remove \(item.path) refused: \(error)", level: .warning)
            return (0, false, "\(item.name): \(error)", nil)
        }
        guard !fileManager.fileExists(atPath: item.path) else {
            return (0, false, "\(item.name): git reported success but the folder is still there", nil)
        }
        Logger.shared.log("Removed worktree \(item.path) (~\(item.size) bytes)", level: .info)
        var note: String?
        if settings.deleteMergedBranch, fresh.verdict.status == .safeToDelete, fresh.branch != nil {
            if let kept = await scanner.deleteMergedBranch(of: fresh, repository: repository) {
                Logger.shared.log("\(item.name): \(kept)", level: .warning)
                note = "\(item.name): \(kept)"
            } else {
                Logger.shared.log("Deleted merged branch \(fresh.branch ?? "") in \(repository)", level: .info)
            }
        }
        return (item.size, true, nil, note)
    }

    /// Deletes the ignored build folders (node_modules, .next, …) of one
    /// worktree and nothing else: the worktree, its tracked files and its
    /// branch stay. Dedicated route, outside the generic allow-list: the
    /// worktree is re-inspected first (still listed by git, not in use, not
    /// locked, not an active agent worktree), then every folder is checked
    /// again (`checkArtifactFolder`: real directory, no symlink, inside the
    /// worktree, same volume, ignored by git, no tracked file) and checked
    /// once more on the filesystem right before it is removed. A folder that
    /// fails any check is left alone and reported; the row counts as cleaned
    /// only when every folder is gone.
    func removeWorktreeArtifacts(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?, note: String?) {
        guard let report = item.worktreeArtifacts else {
            return (0, false, "Not a worktree artifact row: \(item.name)", nil)
        }
        let exclusions = CleanupExclusions.paths()
        guard !CleanupExclusions.excludes(report.worktreePath, paths: exclusions) else {
            return (0, false, "Excluded from cleanup: \(item.name)", nil)
        }
        // The worktree was removed after the scan (for example in the same
        // batch): its build folders went with it.
        guard GitWorktreeScanner.pathExists(report.worktreePath) else { return (0, true, nil, nil) }
        guard let gitPath = GitWorktreeScanner.locateGit() else {
            return (0, false, "git not found — install Homebrew git or the Xcode command-line tools", nil)
        }
        let settings = worktreeSettings()
        var scanner = GitWorktreeScanner(homeDirectory: homeDirectory.path, gitPath: gitPath)
        scanner.inactiveDays = settings.inactiveDays
        scanner.baseBranchOverride = settings.baseBranch
        guard let fresh = await scanner.reinspect(path: report.worktreePath, repository: report.repositoryPath) else {
            return (0, false, "\(item.name): \(report.worktreePath) is no longer a worktree of \(report.repositoryPath)", nil)
        }
        if let blocker = WorktreeArtifactSupport.blocker(for: fresh.verdict) {
            Logger.shared.log("Skipped artifacts in \(report.worktreePath): \(blocker.localizedDescription)", level: .warning)
            return (0, false, "\(item.name): \(blocker.localizedDescription)", nil)
        }

        var freed: Int64 = 0
        var problems: [String] = []
        for folder in report.folders {
            let relative = folder.relativePath
            let absolute = report.worktreePath + "/" + relative
            if CleanupExclusions.excludes(absolute, paths: exclusions) {
                problems.append("\(relative): excluded from cleanup")
                continue
            }
            let check = await scanner.checkArtifactFolder(worktree: report.worktreePath, relative: relative)
            switch check {
            case .missing:
                continue
            case .refused(let reason):
                Logger.shared.log("Left artifact folder \(absolute): \(reason)", level: .warning)
                problems.append("\(relative): \(reason)")
                continue
            case .nestedRepository(_, let at):
                Logger.shared.log("Left artifact folder \(absolute): contains a repository at \(at)", level: .warning)
                problems.append("\(relative): contains a repository (\(at))")
                continue
            case .ok:
                break
            }
            // Narrow the window between the last check and the delete.
            guard case .ok(let resolved) = WorktreeArtifactSupport.check(worktree: report.worktreePath, relative: relative) else {
                problems.append("\(relative): changed while being checked")
                continue
            }
            let bytes = GitWorktreeScanner.allocatedBytes(under: URL(fileURLWithPath: resolved))
            do {
                try fileManager.removeItem(atPath: resolved)
            } catch {
                Logger.shared.log("Could not delete artifact folder \(resolved): \(error.localizedDescription)", level: .warning)
                problems.append("\(relative): \(error.localizedDescription)")
                continue
            }
            guard !GitWorktreeScanner.pathExists(resolved) else {
                problems.append("\(relative): still there after deleting")
                continue
            }
            freed += bytes
            Logger.shared.log("Deleted artifact folder \(resolved) (~\(bytes) bytes)", level: .info)
        }
        guard problems.isEmpty else {
            return (freed, false, "\(item.name): " + problems.joined(separator: "; "), nil)
        }
        return (freed, true, nil, nil)
    }

    // MARK: - Developer Tool Caches

    private struct DevToolOutcome {
        /// Bytes removed (the scan-time size) when `removed`.
        var freed: Int64 = 0
        /// The cache was emptied by this call.
        var removed = false
        /// Nothing is left to do for this row (removed, or already gone).
        var handled = false
        /// Left alone on purpose because the tool is busy; not a failure.
        var skipped = false
        var error: String?
    }

    /// Cleans one `.devToolCaches` row. The path must equal a root in
    /// `DevToolCaches.roots`; symlinked roots are refused; tools that manage
    /// their cache (uv, go) are cleaned through their own CLI; nothing here
    /// escalates to administrator rights.
    private func cleanDevToolCache(_ item: CleanableItem) async -> DevToolOutcome {
        let home = homeDirectory.path
        guard let root = DevToolCaches.root(forPath: item.path, home: home) else {
            let msg = "Unsupported developer tool cache path: \(item.path)"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        }
        guard !DevToolCaches.hasSymlinkBelowHome(item.path, home: home),
              URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path == item.path,
              isSafeToDelete(resolvedPath: item.path) else {
            let msg = "Skipped symlink or unsafe path: \(item.path)"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
            return DevToolOutcome(handled: true)
        }
        guard isDirectory.boolValue else {
            let msg = "Skipped \(item.name): \(item.path) is not a directory"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        }

        switch root.removal {
        case .unlink:
            return unlinkDevToolCache(item)
        case .unlinkUnlessGradleRunning:
            if devTools.isGradleRunning() {
                let msg = "Skipped \(item.name): a Gradle daemon or build is running. Run `gradle --stop`, then clean again."
                Logger.shared.log(msg, level: .info)
                return DevToolOutcome(skipped: true, error: msg)
            }
            return unlinkDevToolCache(item)
        case .uvCacheClean:
            guard let uv = devTools.locate("uv", home: home, fileManager: fileManager) else {
                return unlinkDevToolCache(item)
            }
            return await runUVCacheClean(uv: uv, item: item)
        case .goCleanCache:
            guard let go = devTools.locate("go", home: home, fileManager: fileManager) else {
                return unlinkDevToolCache(item)
            }
            return await runGoClean(go: go, flag: "-cache", envName: "GOCACHE", item: item)
        case .goCleanModcache:
            guard let go = devTools.locate("go", home: home, fileManager: fileManager) else {
                // Module files are read-only; a plain removal would fail midway.
                let msg = "Skipped \(item.name): `go` was not found, so the module cache was left untouched"
                Logger.shared.log(msg, level: .info)
                return DevToolOutcome(skipped: true, error: msg)
            }
            return await runGoClean(go: go, flag: "-modcache", envName: "GOMODCACHE", item: item)
        }
    }

    private func unlinkDevToolCache(_ item: CleanableItem) -> DevToolOutcome {
        // Narrow the TOCTOU window: the root must still be a real directory
        // right before the unlink. A same-user process can still swap a link
        // in between this check and removeItem (see docs/DEV-TOOL-CACHES.md).
        devTools.beforeUnlinkRecheck(item.path)
        guard isUnchangedDevToolRoot(item.path) else {
            let msg = "Aborting delete: path resolution changed between check and unlink for \(item.path)"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        }
        do {
            try fileManager.removeItem(atPath: item.path)
            return DevToolOutcome(freed: item.size, removed: true, handled: true)
        } catch {
            let msg = "\(item.name) at \(item.path): \(error.localizedDescription)"
            Logger.shared.log("Clean failed: \(msg)", level: .error)
            return DevToolOutcome(error: msg)
        }
    }

    /// True while `path` is still a real directory chain below the home
    /// directory: no symlink on the way and the resolved path equals the path.
    private func isUnchangedDevToolRoot(_ path: String) -> Bool {
        !DevToolCaches.hasSymlinkBelowHome(path, home: homeDirectory.path)
            && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }

    /// `uv cache clean --cache-dir <root>`. Never `--force`. uv waits for a
    /// lock another uv process holds instead of failing, so only a run that
    /// outlives the timeout counts as busy. Any non-zero exit is a real error
    /// and its stderr is logged and shown.
    private func runUVCacheClean(uv: String, item: CleanableItem) async -> DevToolOutcome {
        let busy = "Skipped \(item.name): uv did not finish in time; the cache may be locked by another uv process. Close it, then clean again."
        guard isUnchangedDevToolRoot(item.path) else {
            let msg = "Aborting uv cache clean: path resolution changed for \(item.path)"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        }
        do {
            let output = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: uv),
                arguments: ["cache", "clean", "--cache-dir", item.path],
                timeout: devTools.commandTimeout
            )
            if output.status == 0 {
                Logger.shared.log("uv cache clean removed \(item.path)", level: .info)
                return DevToolOutcome(freed: item.size, removed: true, handled: true)
            }
            let stderr = String(decoding: output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.shared.log("uv cache clean exited \(output.status): \(stderr)", level: .error)
            let detail = stderr.isEmpty ? "" : ": \(String(stderr.prefix(300)))"
            return DevToolOutcome(error: "Couldn't clean \(item.name): uv cache clean failed (exit \(output.status))\(detail)")
        } catch ApplicationUpdaterError.timedOut {
            Logger.shared.log("uv cache clean timed out; treating the cache as busy (\(item.path))", level: .info)
            return DevToolOutcome(skipped: true, error: busy)
        } catch {
            Logger.shared.log("uv cache clean failed to run: \(error.localizedDescription)", level: .error)
            return DevToolOutcome(error: "Couldn't run uv: \(error.localizedDescription)")
        }
    }

    /// `go clean -cache` / `go clean -modcache`. `go` cleans whatever
    /// GOCACHE / GOMODCACHE currently point at, which can differ from the row
    /// the user reviewed (an exported variable, `go env -w`). The variable is
    /// read first and the clean runs only when it names exactly this row.
    private func runGoClean(go: String, flag: String, envName: String, item: CleanableItem) async -> DevToolOutcome {
        var environment = ProcessInfo.processInfo.environment
        environment["GOTOOLCHAIN"] = "local"
        do {
            let probe = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: go),
                arguments: ["env", envName],
                timeout: 60,
                environment: environment
            )
            let reported = String(decoding: probe.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.status == 0, !reported.isEmpty else {
                let msg = "Couldn't clean \(item.name): `go env \(envName)` failed"
                Logger.shared.log(msg, level: .error)
                return DevToolOutcome(error: msg)
            }
            // `go env` may have taken a while: compare go's directory in
            // canonical form and re-check the root right before `go clean`.
            let canonicalReported = URL(fileURLWithPath: (reported as NSString).standardizingPath)
                .resolvingSymlinksInPath().path
            guard reported.hasPrefix("/"), canonicalReported == item.path else {
                let msg = "Skipped \(item.name): go uses \(reported), not \(item.path)"
                Logger.shared.log(msg, level: .warning)
                return DevToolOutcome(skipped: true, error: msg)
            }
            guard isUnchangedDevToolRoot(item.path) else {
                let msg = "Aborting go clean: path resolution changed for \(item.path)"
                Logger.shared.log(msg, level: .warning)
                return DevToolOutcome(error: msg)
            }
            let output = try await BrewProcessRunner.run(
                executableURL: URL(fileURLWithPath: go),
                arguments: ["clean", flag],
                timeout: devTools.commandTimeout,
                environment: environment
            )
            guard output.status == 0 else {
                let stderr = String(decoding: output.stderr, as: UTF8.self)
                Logger.shared.log("go clean \(flag) exited \(output.status): \(stderr)", level: .error)
                return DevToolOutcome(error: "Couldn't clean \(item.name): go clean \(flag) failed (exit \(output.status))")
            }
            Logger.shared.log("go clean \(flag) removed \(item.path)", level: .info)
            return DevToolOutcome(freed: item.size, removed: true, handled: true)
        } catch ApplicationUpdaterError.timedOut {
            let msg = "Couldn't clean \(item.name): go did not finish in time"
            Logger.shared.log(msg, level: .warning)
            return DevToolOutcome(error: msg)
        } catch {
            Logger.shared.log("go failed to run: \(error.localizedDescription)", level: .error)
            return DevToolOutcome(error: "Couldn't run go: \(error.localizedDescription)")
        }
    }

    // MARK: - Simulator Runtimes

    /// Deletes one simulator runtime disk image via
    /// `xcrun simctl runtime delete <identifier>`. Uses the scan-time size as
    /// the freed estimate — simctl does not print reclaimable bytes.
    /// When `xcrun` is missing, returns a clear error and does not attempt
    /// a Process launch (avoids a cryptic "No such file" failure).
    func deleteSimulatorRuntime(identifier: String, reportedSize: Int64) async -> (freed: Int64, cleaned: Bool, error: String?) {
        guard SimulatorRuntimeSupport.isXcrunAvailable() else {
            return (0, false, SimulatorRuntimeSupport.missingXcrunMessage)
        }

        let result = SimulatorRuntimeSupport.runXcrun(["simctl", "runtime", "delete", identifier])
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if detail == SimulatorRuntimeSupport.missingXcrunMessage {
                return (0, false, SimulatorRuntimeSupport.missingXcrunMessage)
            }
            if detail.localizedCaseInsensitiveContains("CoreSimulator")
                || detail.localizedCaseInsensitiveContains("simdiskimaged") {
                return (0, false, "Simulator services unavailable — open Xcode once, then try again")
            }
            Logger.shared.log("simctl runtime delete \(identifier) exited \(result.status): \(detail)", level: .error)
            return (0, false, "Couldn't delete simulator runtime \(identifier)")
        }

        Logger.shared.log("Deleted simulator runtime \(identifier) (~\(reportedSize) bytes)", level: .info)
        return (reportedSize, true, nil)
    }

    // MARK: - Purgeable Space

    func purgePurgeableSpace() async -> Int64 {
        // Get current purgeable space first
        let beforeFree = getCurrentFreeSpace()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "purgePurgeable", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let afterFree = getCurrentFreeSpace()
            let freedSpace = afterFree - beforeFree
            return max(0, freedSpace)
        } catch {
            Logger.shared.log("diskutil purge failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    // MARK: - Trash

    func emptyTrash() async -> Int64 {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        var totalFreed: Int64 = 0

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: trashPath)
            for item in contents {
                let fullPath = (trashPath as NSString).appendingPathComponent(item)
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath) {
                    totalFreed += (attrs[.size] as? Int64) ?? 0
                }
                try fileManager.removeItem(atPath: fullPath)
            }
        } catch {
            Logger.shared.log("Trash cleanup incomplete: \(error.localizedDescription)", level: .warning)
        }

        return totalFreed
    }

    // MARK: - Helpers

    /// Internal so tests can prove what both the user pass and the admin pass refuse.
    func isSafeToDelete(
        item: CleanableItem,
        resolvedPath: String,
        includeUninstallPaths: Bool = false
    ) -> Bool {
        // Docker/OrbStack VM disks sit under allow-listed roots; refuse them
        // first, for every category and in both the user and admin pass.
        if DockerSupport.isProtectedDiskPath(item.path, homeDirectory: homeDirectory)
            || DockerSupport.isProtectedDiskPath(resolvedPath, homeDirectory: homeDirectory) {
            Logger.shared.log("Refusing to delete Docker/OrbStack disk state: \(resolvedPath)", level: .warning)
            return false
        }
        if item.category == .aiApps {
            return item.path == resolvedPath && isSupportedAIAppPath(resolvedPath)
        }
        // Local AI Models rows have their own validated route in cleanItems;
        // if one ever reaches the generic path it must not be deletable here.
        if item.category == .localAIModels {
            return false
        }
        let originalIsManaged = XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            item.path,
            homeDirectory: homeDirectory
        )
        let resolvedIsManaged = XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(
            resolvedPath,
            homeDirectory: homeDirectory
        )

        // A managed path must remain managed after symlink resolution. Do not
        // fall through to broader roots such as Application Support: that
        // would turn a symlinked XcodeBuildMCP root into an allow-list bypass.
        if originalIsManaged || resolvedIsManaged {
            let original = (item.path as NSString).standardizingPath
            let resolved = (resolvedPath as NSString).standardizingPath
            return originalIsManaged && resolvedIsManaged && original == resolved
        }
        if item.category == .largeFiles {
            return isExplicitSingleFileDeletable(resolvedPath: resolvedPath)
        }
        return isSafeToDelete(resolvedPath: resolvedPath)
            || (includeUninstallPaths && isSafeUninstallEscalationPath(resolvedPath))
    }

    private func isSupportedAIAppPath(_ path: String) -> Bool {
        guard !path.utf8.contains(0), path == (path as NSString).standardizingPath else { return false }
        let home = homeDirectory.path
        return [
            "\(home)/.ollama/logs",
            "\(home)/.ollama/history",
            "\(home)/.lmstudio/server-logs",
            "\(home)/.lmstudio/conversations",
            "\(home)/Library/Caches/ollama",
            "\(home)/Library/Caches/com.electron.ollama",
            "\(home)/Library/WebKit/com.electron.ollama",
            "\(home)/Library/Saved Application State/com.electron.ollama.savedState",
        ].contains(path)
    }

    /// Validates that a resolved path is safe to delete.
    /// Prevents symlink attacks where a link in ~/Library/Caches points to ~/.ssh.
    /// Downloads, Documents, and Desktop are intentionally NOT whole-subtree
    /// allow-listed - scanLargeFiles emits per-file items instead, so those
    /// deletions can still happen through the explicit per-item flow.
    private func isSafeToDelete(resolvedPath: String) -> Bool {
        let home = homeDirectory.path
        // Cloud File Provider state is never deletable, whatever category asked
        // and whichever allowed root it happens to sit under (issue #142).
        // Checked before the allowlist because several provider directories live
        // inside ~/Library/Caches and ~/Library/Application Support, which are
        // themselves allowed roots.
        if ProviderPaths.isProviderOwned(resolvedPath, homeDirectory: homeDirectory) {
            Logger.shared.log(
                "Refusing to delete cloud provider state: \(resolvedPath)",
                level: .warning
            )
            return false
        }
        // Same for Docker/OrbStack disks (also checked per item above).
        if DockerSupport.isProtectedDiskPath(resolvedPath, homeDirectory: homeDirectory) {
            Logger.shared.log("Refusing to delete Docker/OrbStack disk state: \(resolvedPath)", level: .warning)
            return false
        }

        let allowedRoots = Self.allowedDeletionRoots(home: home)
        // Either the path equals an allow-listed root (whole-subtree wipe by
        // the scanner that emits the root itself, e.g. DerivedData) or it
        // sits strictly inside one. The trailing "/" on the prefix match
        // prevents siblings like "/tmpfoo" from sneaking past "/tmp".
        let normalized = (resolvedPath as NSString).standardizingPath
        return allowedRoots.contains { root in
            if normalized == root { return true }
            let rootWithSeparator = root.hasSuffix("/") ? root : root + "/"
            return normalized.hasPrefix(rootWithSeparator)
        }
    }

    /// Roots under which the generic delete path may remove items.
    nonisolated static func allowedDeletionRoots(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Support",
            "\(home)/Library/Preferences",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Mail Downloads",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
            "\(home)/Library/Developer/XCTestDevices",
            "\(home)/Library/Developer/Xcode/UserData/Previews",
            "\(home)/Library/org.swift.swiftpm",
            "\(home)/Library/pnpm/store",
            "\(home)/.Trash",
            "\(home)/.npm",
            "\(home)/.pnpm-store",
            "\(home)/.cache",
            "\(home)/.local/share/pnpm/store",
            // Docker Desktop: only the folders scanDockerCache surfaces, never
            // the container as a whole (it holds vms/…/Docker.raw).
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            // Docker/OrbStack cache + log roots surfaced by scanDockerCache.
            // Without these the items scan fine but every delete is refused
            // as "unsafe path" — the category looked broken. Narrow roots
            // only; ~/.docker itself holds config.json and TLS certs, and
            // ~/.orbstack/data is the VM disk, so neither is allow-listed.
            "\(home)/.docker/cli-plugins/.cache",
            "\(home)/.docker/buildx/cache",
            "\(home)/.orbstack/log",
            "/Library/Caches",
            "/Library/Logs",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            "/private/var/log",
            "/private/var/tmp",
            "/private/tmp",
            // /var is a symlink to /private/var, and resolvingSymlinksInPath
            // gives the /var form. Both spellings must be allow-listed or
            // every system log/tmp deletion silently fails the safety check.
            "/var/log",
            "/var/tmp",
            "/tmp",
            // Developer tool cache roots surfaced by scanDevToolCaches: exact
            // directories only (see DevToolCaches.roots). Without them roots
            // outside ~/Library/Caches and ~/.cache, such as ~/.bun and
            // ~/.cargo/registry/cache, would be refused as unsafe. Parents
            // (~/.cargo, ~/.gradle, ~/.m2, ~/go) are never allow-listed.
        ] + DevToolCaches.absolutePaths(home: home)
    }

    /// A removable localization folder inside an installed app bundle:
    /// /Applications/.../<App>.app/Contents/Resources/<lang>.lproj (or the
    /// same shape under ~/Applications), where <lang> is neither in the
    /// scanner's keep-set (user-preferred languages plus en/English/Base)
    /// nor the bundle's development region. Everything else — including any
    /// other path inside an app bundle — stays blocked.
    private func isRemovableLprojPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        guard (normalized as NSString).pathExtension.lowercased() == "lproj" else { return false }

        let home = fileManager.homeDirectoryForCurrentUser.path
        guard isInside(normalized, root: "/Applications") || isInside(normalized, root: "\(home)/Applications") else {
            return false
        }

        // Must sit exactly at <bundle>.app/Contents/Resources/<lang>.lproj.
        let resources = (normalized as NSString).deletingLastPathComponent
        let contents = (resources as NSString).deletingLastPathComponent
        let bundle = (contents as NSString).deletingLastPathComponent
        guard (resources as NSString).lastPathComponent == "Resources",
              (contents as NSString).lastPathComponent == "Contents",
              (bundle as NSString).lastPathComponent.lowercased().hasSuffix(".app") else {
            return false
        }

        let language = ((normalized as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        // Same keep-set as the scanner (user-preferred languages plus the
        // en/English/Base fallbacks), so a stale or replayed item list can
        // never delete a localization the user's current settings depend on.
        if LanguageFilesScanner().keepLanguages.contains(language) { return false }
        // The bundle's development region is its last-resort fallback
        // localization — often the only complete one. Deleting it leaves
        // NSLocalizedString returning raw keys or breaks nib loading.
        if let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
           let region = plist["CFBundleDevelopmentRegion"] as? String {
            let normalizedRegion = region.lowercased().replacingOccurrences(of: "_", with: "-")
            if language == normalizedRegion { return false }
            if let base = normalizedRegion.split(separator: "-").first, language == String(base) {
                return false
            }
        }
        return true
    }

    /// Runs BinaryThinner for one .universalBinaries item (path = app
    /// bundle). Re-scans the bundle first so the lipo work list reflects the
    /// bundle's current state, not the possibly stale scan result.
    private func thinUniversalBinaryItem(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?) {
        let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
        guard isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "/Applications")
            || isAppBundlePath((resolved as NSString).standardizingPath, rootedAt: "\(fileManager.homeDirectoryForCurrentUser.path)/Applications") else {
            let msg = "Skipped unsafe path for thinning: \(item.path) -> \(resolved)"
            Logger.shared.log(msg, level: .warning)
            return (0, false, msg)
        }

        guard let finding = UniversalBinaryScanner().finding(forAppAt: resolved) else {
            // Nothing fat left — the app was thinned or replaced since the
            // scan. Count it handled so it doesn't surface as a failure.
            Logger.shared.log("No removable slices left in \(item.path); marking handled", level: .info)
            return (0, true, nil)
        }

        switch await binaryThinner.thin(finding) {
        case .success(let freed):
            return (freed, true, nil)
        case .failure(let error):
            if case BinaryThinner.ThinningError.needsAdmin = error {
                let msg = "\(item.name): needs administrator access to thin; skipped"
                Logger.shared.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't thin \(item.name): \(error.localizedDescription)"
            Logger.shared.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// Routes one .languageFiles item (path = .lproj folder) through
    /// BinaryThinner's staged clone / re-sign / verify / swap flow. The
    /// folder is validated against the same .lproj predicate as before,
    /// then removed from a staged copy of the bundle so the signature seal
    /// stays consistent with the bundle's contents.
    private func removeLanguageFileItem(_ item: CleanableItem) async -> (freed: Int64, cleaned: Bool, error: String?) {
        let resolved = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path
        let normalized = (resolved as NSString).standardizingPath
        guard isRemovableLprojPath(normalized) else {
            let msg = "Skipped symlink or unsafe path: \(item.path) -> \(resolved)"
            Logger.shared.log(msg, level: .warning)
            return (0, false, msg)
        }

        guard fileManager.fileExists(atPath: normalized) else {
            // Already gone (app updated or reinstalled since the scan) —
            // count it handled so it doesn't surface as a failure.
            return (0, true, nil)
        }

        // <lang>.lproj -> Resources -> Contents -> bundle; the shape was
        // just validated by isRemovableLprojPath.
        let bundle = (((normalized as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent as NSString).deletingLastPathComponent

        switch await binaryThinner.removeLproj(at: normalized, fromAppAt: bundle) {
        case .success:
            return (item.size, true, nil)
        case .failure(let error):
            if case BinaryThinner.ThinningError.needsAdmin = error {
                let msg = "\(item.name): needs administrator access to modify the app; skipped"
                Logger.shared.log(msg, level: .warning)
                return (0, false, msg)
            }
            let msg = "Couldn't remove localization \(item.name): \(error.localizedDescription)"
            Logger.shared.log(msg, level: .error)
            return (0, false, msg)
        }
    }

    /// Allows the app uninstaller to escalate only the protected roots it owns:
    /// app bundles, package receipts, and launch plists. This intentionally
    /// stays narrower than the normal cleaner allow-list.
    private func isSafeUninstallEscalationPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = fileManager.homeDirectoryForCurrentUser.path

        return isAppBundlePath(normalized, rootedAt: "/Applications")
            || isAppBundlePath(normalized, rootedAt: "\(home)/Applications")
            || isReceiptPath(normalized, rootedAt: "/private/var/db/receipts")
            || isReceiptPath(normalized, rootedAt: "/var/db/receipts")
            || isPlistUnder(normalized, root: "/Library/LaunchDaemons")
            || isPlistUnder(normalized, root: "/Library/LaunchAgents")
    }

    private func isAppBundlePath(_ path: String, rootedAt root: String) -> Bool {
        guard isInside(path, root: root) else { return false }
        let normalizedRoot = (root as NSString).standardizingPath
        guard path != normalizedRoot else { return false }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        let relative = String(path.dropFirst(rootWithSeparator.count))
        return relative.split(separator: "/").contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    private func isReceiptPath(_ path: String, rootedAt root: String) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard parent == (root as NSString).standardizingPath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "plist" || ext == "bom"
    }

    private func isPlistUnder(_ path: String, root: String) -> Bool {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath
        return parent == (root as NSString).standardizingPath && (path as NSString).pathExtension.lowercased() == "plist"
    }

    private func isInside(_ path: String, root: String) -> Bool {
        let normalizedRoot = (root as NSString).standardizingPath
        if path == normalizedRoot { return true }
        let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return path.hasPrefix(rootWithSeparator)
    }

    private func hasUnexpectedSymlink(in path: String) -> Bool {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" {
            let current = url.path
            let type = (try? fileManager.attributesOfItem(atPath: current)[.type]) as? FileAttributeType
            if type == .typeSymbolicLink, current != "/tmp", current != "/var" {
                return true
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == current { break }
            url = parent
        }
        return false
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Allow a single-file delete under Downloads/Documents/Desktop when it
    /// was explicitly surfaced by a scanner (e.g. scanLargeFiles). Whole-subtree
    /// deletion of those roots remains blocked.
    func isExplicitSingleFileDeletable(resolvedPath: String) -> Bool {
        let home = homeDirectory.path
        let perFileRoots = [
            "\(home)/Downloads/",
            "\(home)/Documents/",
            "\(home)/Desktop/",
        ]
        let normalized = (resolvedPath as NSString).standardizingPath
        return perFileRoots.contains { normalized.hasPrefix($0) }
    }

    private func getCurrentFreeSpace() -> Int64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            Logger.shared.log("Cannot read filesystem attributes: \(error.localizedDescription)", level: .warning)
            return 0
        }
    }
}
