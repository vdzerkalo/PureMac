import Foundation

/// CLI discovery + `docker system df` parsing for the Docker category.
/// Kept free of Process I/O so unit tests can cover the scan/clean contract
/// without a running Docker daemon.
enum DockerSupport {
    struct DiskUsageRow: Equatable {
        /// "Images", "Containers", "Local Volumes" or "Build Cache".
        let type: String
        let size: Int64
        let reclaimable: Int64
    }

    /// Where Docker Desktop and OrbStack install the `docker` CLI. The
    /// /usr/local/bin and /opt/homebrew/bin links are optional: Docker
    /// Desktop's "user" install only writes ~/.docker/bin, and the app bundle
    /// copy exists even when the user declined the system symlinks.
    static func candidateBinaryPaths(homeDirectory: String) -> [String] {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(homeDirectory)/.docker/bin/docker",
            "\(homeDirectory)/.orbstack/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
    }

    static func locateBinary(
        homeDirectory: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidateBinaryPaths(homeDirectory: homeDirectory).first(where: isExecutable)
    }

    /// Arguments for a `docker system df` that prints one JSON object per
    /// line. `{{json .}}` rather than `--format json` so older CLIs work too.
    static let systemDFArguments = ["system", "df", "--format", "{{json .}}"]

    /// Parse stdout from `docker system df --format '{{json .}}'`.
    /// Lines that are not a JSON object with Type/Size/Reclaimable are skipped.
    static func parseSystemDF(_ output: String) -> [DiskUsageRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String,
                  let sizeText = object["Size"] as? String,
                  let reclaimableText = object["Reclaimable"] as? String,
                  let size = parseHumanBytes(sizeText),
                  // "1.234GB (45%)" — the percentage is informational only.
                  let reclaimable = parseHumanBytes(String(reclaimableText.split(separator: " ").first ?? ""))
            else { return nil }
            return DiskUsageRow(type: type, size: size, reclaimable: reclaimable)
        }
    }

    /// One reclaim action per Docker object kind, each run as its own prune
    /// so the user can keep, say, images while dropping build cache.
    /// Every action except `danglingImages` is scoped to what df reports as
    /// reclaimable for its row, which is why images, volumes and build cache
    /// use `-a`: without it the command frees only dangling objects, a
    /// fraction of the promised size. `danglingImages` is the narrower
    /// `docker image prune -f`, a subset of what `unusedImages` removes.
    /// Declaration order is the display order; `cleanOrder` is the run order.
    enum PruneAction: String, CaseIterable {
        case buildCache = "build-cache"
        case stoppedContainers = "containers"
        case danglingImages = "dangling-images"
        case unusedImages = "images"
        case unusedVolumes = "volumes"

        /// The `Type` column of the `docker system df` row this action frees.
        /// Dangling images sit inside the "Images" row, but df does not break
        /// them out; their estimate comes from `danglingEstimate`.
        var diskUsageType: String {
            switch self {
            case .buildCache: return "Build Cache"
            case .stoppedContainers: return "Containers"
            case .danglingImages, .unusedImages: return "Images"
            case .unusedVolumes: return "Local Volumes"
            }
        }

        /// Fixed arguments. Volumes are different: there is no prune, only
        /// `docker volume rm` on the exact names recorded at scan time, which
        /// live in the row's path. This base is never run without names; use
        /// `DockerSupport.arguments(forPath:)`.
        var arguments: [String] {
            switch self {
            case .buildCache: return ["builder", "prune", "-a", "-f"]
            case .stoppedContainers: return ["container", "prune", "-f"]
            case .danglingImages: return ["image", "prune", "-f"]
            case .unusedImages: return ["image", "prune", "-a", "-f"]
            case .unusedVolumes: return ["volume", "rm"]
            }
        }

        /// Run order when several rows are selected. Volumes go FIRST, before
        /// the container prune: a stopped container holds its volumes, and
        /// removing the container would make them "unused" after the user
        /// reviewed a list that did not include them. Run first, the volume
        /// removal only ever sees the volumes that were unused at scan time.
        /// Containers then release the images they used, so the image prunes
        /// find more (estimates only under-promise). Dangling images go
        /// before `image prune -a`, so the second command reports only what
        /// is left and the two "Total reclaimed space" lines add up without
        /// overlap. Build cache is independent and can run for minutes, so
        /// it is last.
        var cleanOrder: Int {
            switch self {
            case .unusedVolumes: return 0
            case .stoppedContainers: return 1
            case .danglingImages: return 2
            case .unusedImages: return 3
            case .buildCache: return 4
            }
        }

        /// The exact command, shown in the removal review so the user sees
        /// what will run instead of a generic "cleanup action".
        var commandLine: String {
            (["docker"] + arguments).joined(separator: " ")
        }

        /// Volumes hold user data (databases, uploads) that no pull or build
        /// can recreate. They are never preselected and never picked up by
        /// "Select visible" or the category checkbox, only by a click on the row.
        var requiresExplicitSelection: Bool {
            self == .unusedVolumes
        }
    }

    /// Path prefix for the virtual rows cleaned through a docker prune
    /// command rather than a filesystem unlink. Distinct per action so rows
    /// survive path-based dedupe and cleanedPaths bookkeeping.
    static let actionPathPrefix = "docker-prune:"

    /// `docker-prune:<action>`. The volumes row also carries the volumes
    /// recorded at scan time: `docker-prune:volumes:<name>=<bytes>,…`. Volume
    /// names only contain `[A-Za-z0-9_.-]`, so `:`, `,` and `=` are safe
    /// separators; names that do not match are never encoded.
    static func actionPath(for action: PruneAction, volumes: [VolumeEntry] = []) -> String {
        var path = actionPathPrefix + action.rawValue
        let valid = volumes.filter { isValidVolumeName($0.name) }
        if action == .unusedVolumes, !valid.isEmpty {
            path += ":" + valid.map { "\($0.name)=\($0.bytes)" }.joined(separator: ",")
        }
        return path
    }

    static func action(forPath path: String) -> PruneAction? {
        guard path.hasPrefix(actionPathPrefix) else { return nil }
        let rest = path.dropFirst(actionPathPrefix.count)
        let raw = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return PruneAction(rawValue: String(raw))
    }

    /// The volumes recorded in a volumes row's path; empty for any other
    /// path and for entries whose name is not a valid volume name.
    static func volumeEntries(forPath path: String) -> [VolumeEntry] {
        guard action(forPath: path) == .unusedVolumes else { return [] }
        let rest = path.dropFirst(actionPathPrefix.count)
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return [] }
        return parts[1].split(separator: ",").compactMap { token in
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, isValidVolumeName(String(pair[0])), let bytes = Int64(pair[1]), bytes >= 0
            else { return nil }
            return VolumeEntry(name: String(pair[0]), bytes: bytes)
        }
    }

    /// The command a Docker row runs. Fixed for every row except volumes,
    /// which is `volume rm` + the recorded names (nil when the row records
    /// none: it must never run as a bare `volume rm`).
    static func arguments(forPath path: String) -> [String]? {
        guard let action = action(forPath: path) else { return nil }
        guard action == .unusedVolumes else { return action.arguments }
        let names = volumeEntries(forPath: path).map(\.name)
        return names.isEmpty ? nil : action.arguments + names
    }

    static func commandLine(forPath path: String) -> String? {
        guard let action = action(forPath: path) else { return nil }
        guard let arguments = arguments(forPath: path) else { return action.commandLine }
        return (["docker"] + arguments).joined(separator: " ")
    }

    /// One row of the scan: what a Docker action will free.
    struct PruneEstimate {
        let action: PruneAction
        let bytes: Int64
        let sizeKnown: Bool
        /// Volumes the row will remove (volumes row only).
        let volumes: [VolumeEntry]
    }

    /// Reclaimable bytes per action, in display order, skipping empty rows.
    ///
    /// The two image rows are made disjoint so that selecting both adds up to
    /// what the clean can free instead of counting the dangling images twice:
    /// the `image prune -a` row shows df's figure minus the dangling
    /// estimate. Run alone it frees at least that, so it under-promises.
    ///
    /// The dangling row is the one place a size can be unknown. It is listed
    /// whenever prunable dangling images exist; without a reliable figure it
    /// has `bytes == 0` and `sizeKnown == false` (a computed 0 counts as no
    /// figure: all its layers are shared). Zero there means "not
    /// estimated", never "frees nothing", and the UI labels it as such.
    ///
    /// The volumes row never comes from df's "Local Volumes" figure: it lists
    /// exactly the volumes recorded by `volumeEstimate`, and its size is the
    /// sum of those volumes, so the number shown and the volumes removed are
    /// the same set.
    static func pruneEstimates(
        _ rows: [DiskUsageRow],
        dangling: DanglingEstimate? = nil,
        volumes: VolumeEstimate? = nil
    ) -> [PruneEstimate] {
        let danglingBytes = dangling?.bytes ?? 0
        return PruneAction.allCases.compactMap { action in
            switch action {
            case .danglingImages:
                guard dangling != nil else { return nil }
                return PruneEstimate(action: action, bytes: danglingBytes, sizeKnown: danglingBytes > 0, volumes: [])
            case .unusedVolumes:
                guard let volumes else { return nil }
                return PruneEstimate(action: action, bytes: volumes.bytes, sizeKnown: volumes.bytes > 0, volumes: volumes.entries)
            default:
                var bytes = rows
                    .filter { $0.type == action.diskUsageType }
                    .reduce(0) { $0 + $1.reclaimable }
                if action == .unusedImages { bytes = max(bytes - danglingBytes, 0) }
                return bytes > 0 ? PruneEstimate(action: action, bytes: bytes, sizeKnown: true, volumes: []) : nil
            }
        }
    }

    // MARK: - Unused volumes

    /// Volume names are `[A-Za-z0-9][A-Za-z0-9_.-]*`. Anything else is never
    /// passed to docker, so a name cannot become an option or a path.
    static func isValidVolumeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." || $0 == "-")
        }
    }

    /// Volumes no container references, running or stopped: the set
    /// `docker volume prune -a` would remove, and the only ones a volumes
    /// row may remove. Recorded at scan time, re-checked right before removal.
    static let unusedVolumeNamesArguments = ["volume", "ls", "-q", "--filter", "dangling=true"]

    struct VolumeEntry: Equatable {
        let name: String
        /// Bytes at scan time (0 when docker reported none).
        let bytes: Int64
    }

    struct VolumeUsage: Equatable {
        let name: String
        /// Containers, running or stopped, that reference the volume.
        let links: Int
        /// nil when docker printed no size ("N/A").
        let size: Int64?
    }

    struct VolumeEstimate: Equatable {
        let entries: [VolumeEntry]
        var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    }

    /// Volume names from `unusedVolumeNamesArguments` output; invalid names
    /// are dropped.
    static func parseVolumeNames(_ output: String) -> [String] {
        parseImageIDs(output).filter(isValidVolumeName)
    }

    /// The Volumes array of `docker system df -v --format '{{json .}}'`; nil
    /// when the output is not that JSON object.
    static func parseVolumeUsage(_ output: String) -> [VolumeUsage]? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]]
        else { return nil }
        return volumes.compactMap { volume in
            guard let name = volume["Name"] as? String,
                  let linksText = volume["Links"] as? String,
                  let links = Int(linksText)
            else { return nil }
            return VolumeUsage(name: name, links: links, size: (volume["Size"] as? String).flatMap(parseHumanBytes))
        }
    }

    /// The volumes a row may remove, with their sizes. Names come from the
    /// dangling filter; df -v only supplies sizes (a volume's size is its own
    /// data, nothing is shared, so the sum is exact apart from Docker's
    /// rounding). A volume df says is referenced by a container is dropped; a
    /// volume without a size counts 0 bytes.
    /// - Returns: nil when there is nothing to remove or the names are unknown.
    static func volumeEstimate(names: [String]?, usage: [VolumeUsage]?) -> VolumeEstimate? {
        guard let names, !names.isEmpty else { return nil }
        let byName = Dictionary((usage ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let entries: [VolumeEntry] = names.compactMap { name in
            guard isValidVolumeName(name), seen.insert(name).inserted else { return nil }
            guard let known = byName[name] else { return VolumeEntry(name: name, bytes: 0) }
            guard known.links == 0 else { return nil }
            return VolumeEntry(name: name, bytes: known.size ?? 0)
        }
        return entries.isEmpty ? nil : VolumeEstimate(entries: entries)
    }

    /// Splits the result of `docker volume rm <names>`. Docker prints each
    /// removed name on stdout and one error line per failure on stderr. A
    /// volume that no longer exists ("no such volume") is skipped silently;
    /// every other failure (typically "volume is in use") is reported.
    static func parseVolumeRemoval(
        stdout: String,
        stderr: String,
        requested: [VolumeEntry]
    ) -> (removed: [VolumeEntry], problems: [String], vanished: Int) {
        let printed = Set(parseImageIDs(stdout))
        let removed = requested.filter { printed.contains($0.name) }
        var vanished = 0
        var problems: [String] = []
        for line in stderr.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            // Only a "no such volume" that names a volume we asked for is a
            // quiet skip; any other line is reported.
            let words = Set(line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }).map(String.init))
            if line.lowercased().contains("no such volume"),
               requested.contains(where: { words.contains($0.name) }) {
                vanished += 1
                continue
            }
            let prefix = "Error response from daemon: "
            problems.append("docker volume rm: " + (line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line))
        }
        return (removed, problems, vanished)
    }

    // MARK: - Dangling images

    /// Lists the IDs `docker image prune -f` targets. `dangling=true` is the
    /// filter prune itself uses; `--no-trunc` prints full `sha256:` IDs so
    /// they match `docker system df -v` exactly.
    static let danglingImageIDsArguments = ["images", "--filter", "dangling=true", "--no-trunc", "--format", "{{.ID}}"]

    /// `docker system df -v` as one JSON object holding the Images,
    /// Containers, Volumes and BuildCache arrays. Only run when dangling
    /// images exist: it measures every volume and can take seconds.
    static let verboseSystemDFArguments = ["system", "df", "-v", "--format", "{{json .}}"]

    /// Limit for each dangling lookup; the daemon may be wedged.
    static let danglingLookupTimeout: TimeInterval = 30

    struct ImageUsage: Equatable {
        /// Full image ID, `sha256:…`.
        let id: String
        /// Containers, running or stopped, created from the image.
        let containers: Int
        /// Bytes of layers no other image uses (df's UNIQUE SIZE).
        let uniqueSize: Int64
    }

    struct DanglingEstimate: Equatable {
        /// Dangling images no container uses, i.e. what prune can remove.
        let count: Int
        /// Lower bound of the bytes `docker image prune -f` frees; nil when
        /// `docker system df -v` gave no usable figure.
        let bytes: Int64?
    }

    /// Image IDs from `danglingImageIDsArguments` output, one per line.
    static func parseImageIDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    /// The Images array of `docker system df -v --format '{{json .}}'`.
    /// Entries missing an ID, container count or unique size are skipped; nil
    /// when the output is not that JSON object at all.
    static func parseImageUsage(_ output: String) -> [ImageUsage]? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["Images"] as? [[String: Any]]
        else { return nil }
        return images.compactMap { image in
            guard let id = image["ID"] as? String,
                  let containersText = image["Containers"] as? String,
                  let containers = Int(containersText),
                  let uniqueText = image["UniqueSize"] as? String,
                  let unique = parseHumanBytes(uniqueText)
            else { return nil }
            return ImageUsage(id: id, containers: containers, uniqueSize: unique)
        }
    }

    /// What `docker image prune -f` can free, as a lower bound.
    ///
    /// Why a lower bound: layers are shared between images, so an image's
    /// SIZE overstates what removing it frees. df's UNIQUE SIZE counts only
    /// layers no other image uses, so deleting the image frees at least that.
    /// Layers shared only among the dangling images, or with an image that
    /// goes in the same prune, are not counted: the figure can be too low,
    /// never too high (apart from Docker rounding its output to four digits).
    ///
    /// Why the IDs do not come from df's own `<none>` rows: on the containerd
    /// image store df -v also lists digest-only references (`repo@sha256:…`)
    /// as `<none>:<none>`, and `image prune -f` keeps those. The dangling IDs
    /// therefore come from the filter prune uses; df -v only supplies sizes.
    ///
    /// - Parameters:
    ///   - danglingIDs: parsed `danglingImageIDsArguments` output; nil when
    ///     that command failed, which offers no row (nothing is known).
    ///   - usage: parsed `docker system df -v` Images; nil when unavailable.
    /// - Returns: nil when there is nothing to prune.
    static func danglingEstimate(danglingIDs: [String]?, usage: [ImageUsage]?) -> DanglingEstimate? {
        guard let danglingIDs, !danglingIDs.isEmpty else { return nil }
        guard let usage else { return DanglingEstimate(count: danglingIDs.count, bytes: nil) }
        let byID = Dictionary(usage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var count = 0
        var bytes: Int64 = 0
        for id in danglingIDs {
            guard let image = byID[id] else {
                // Not in df's list (created in between): prune may remove it,
                // but no size is promised for it.
                count += 1
                continue
            }
            // Prune keeps any image a container (even a stopped one) uses.
            guard image.containers == 0 else { continue }
            count += 1
            bytes += image.uniqueSize
        }
        guard count > 0 else { return nil }
        return DanglingEstimate(count: count, bytes: bytes)
    }

    /// Puts the Docker prune rows in `PruneAction.cleanOrder`; every other
    /// item keeps its position, Docker rows only swap among the slots Docker
    /// rows already occupied.
    static func orderedForCleaning(_ items: [CleanableItem]) -> [CleanableItem] {
        let slots = items.indices.filter { items[$0].dockerPruneAction != nil }
        let ordered = slots
            .sorted { lhs, rhs in
                let l = items[lhs].dockerPruneAction?.cleanOrder ?? 0
                let r = items[rhs].dockerPruneAction?.cleanOrder ?? 0
                return l == r ? lhs < rhs : l < r
            }
            .map { items[$0] }
        var result = items
        for (slot, item) in zip(slots, ordered) { result[slot] = item }
        return result
    }

    /// Parse the freed-bytes summary a prune prints last: "Total reclaimed
    /// space: 1.2GB" for container/image/volume prune, "Total:\t1.2GB" for
    /// builder prune. Returns nil when no summary line is present.
    static func parseReclaimedSpace(_ output: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for label in ["Total reclaimed space:", "Total:"] where trimmed.hasPrefix(label) {
                return parseHumanBytes(String(trimmed.dropFirst(label.count)))
            }
        }
        return nil
    }

    /// Docker Desktop's VM disk. Docker's Mac FAQ says other tools may show
    /// its maximum size instead of the space it actually uses, so the
    /// allocated size is what is reported. A prune frees space inside the VM;
    /// per the same FAQ it "might take a few minutes to reclaim space on the
    /// host", and `docker run --privileged --pid=host docker/desktop-reclaim-space`
    /// triggers it on demand. PureMac only reports the file and never runs
    /// that command or deletes it. Source and details: docs/DOCKER.md.
    static func dockerRawPath(homeDirectory: String) -> String {
        "\(homeDirectory)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
    }

    static func allocatedSize(ofFileAt path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let size = values.totalFileAllocatedSize
        else { return nil }
        return Int64(size)
    }

    /// Parse Docker's compact size format ("1.23GB", "456MB", "789kB", "0B").
    static func parseHumanBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        for (suffix, multiplier) in units {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let value = Double(numberPart) {
                    return Int64(value * multiplier)
                }
            }
        }
        return nil
    }

    /// Classify a failed docker invocation's stderr. Docker Desktop and
    /// OrbStack both stop their daemon on demand, so "not running" is the
    /// common case and deserves a friendly message rather than an exit code.
    ///
    /// Only the CLI's own connection errors count. Any text containing
    /// "daemon" does not: "Error response from daemon: a prune operation is
    /// already running" comes from a running daemon and must not read as
    /// "Docker isn't running".
    static func isDaemonUnavailable(stderr: String) -> Bool {
        ["Cannot connect to the Docker daemon", "Is the docker daemon running", "dial unix"]
            .contains { stderr.contains($0) }
    }

    /// Docker wording for a failed run, instead of the Homebrew text
    /// `ApplicationUpdaterError` carries (the runner is shared with brew).
    static func describe(_ error: Error, timeout: TimeInterval) -> String {
        switch error as? ApplicationUpdaterError {
        case .timedOut:
            return "timed out after \(Int(timeout))s"
        case .outputLimitExceeded:
            return "printed more output than PureMac can read"
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Files PureMac must never unlink

    /// True for Docker Desktop and OrbStack VM disks, their state, and the
    /// folders that contain them. They sit under allow-listed roots
    /// (`~/Library/Containers`, `~/Library/Group Containers`), so this is
    /// checked BEFORE the allow-list, for the literal and the symlink-resolved
    /// path, on a case-insensitive basis (default APFS volumes are
    /// case-insensitive). Images, containers and volumes live inside these
    /// disks; only the docker CLI may remove them.
    ///
    /// Denied: `Library/Containers/com.docker.docker/Data/vms` and the
    /// container itself and its `Data` folder (their removal takes `vms` with
    /// it); `Library/Group Containers/group.com.docker` except its `Caches`
    /// subtree; `Library/Group Containers/<team>.dev.orbstack` and its `data`;
    /// `.orbstack` and `.orbstack/data`; `.docker/desktop`. An item equal to
    /// any ancestor of those roots is refused too (`~`, `~/Library`,
    /// `~/Library/Containers`, `~/Library/Group Containers`, `~/.docker`):
    /// removing a parent takes the disk with it, and the first two folders are
    /// whole-folder allow-list roots.
    static func isProtectedDiskPath(_ path: String, homeDirectory: URL) -> Bool {
        let resolvedHome = homeDirectory.resolvingSymlinksInPath()
        var homes: [String] = []
        for home in [homeDirectory.standardizedFileURL.path, resolvedHome.path, resolvedHome.standardizedFileURL.path]
        where !homes.contains(home) {
            homes.append(home)
        }
        let candidates = [
            (path as NSString).standardizingPath,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
        ].map { $0.lowercased() }

        func within(_ candidate: String, _ root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root + "/")
        }

        for home in homes.map({ $0.lowercased() }) {
            let docker = home + "/library/containers/com.docker.docker"
            let group = home + "/library/group containers/group.com.docker"
            let groupContainers = home + "/library/group containers/"
            let ancestors = [home, home + "/library", home + "/library/containers", home + "/library/group containers", home + "/.docker"]
            for candidate in candidates {
                if ancestors.contains(candidate) { return true }
                if candidate == docker || candidate == docker + "/data" || within(candidate, docker + "/data/vms") { return true }
                if candidate == group || (candidate.hasPrefix(group + "/") && !within(candidate, group + "/caches")) { return true }
                if candidate == home + "/.orbstack" || within(candidate, home + "/.orbstack/data") { return true }
                if within(candidate, home + "/.docker/desktop") { return true }
                if candidate.hasPrefix(groupContainers) {
                    let parts = candidate.dropFirst(groupContainers.count).split(separator: "/", omittingEmptySubsequences: false)
                    if let first = parts.first, first.hasSuffix(".dev.orbstack"),
                       parts.count == 1 || parts[1] == "data" { return true }
                }
            }
        }
        return false
    }

    /// A prune of a large build cache can run for minutes; the limit only
    /// exists so a wedged daemon can't hang the clean forever.
    static let pruneTimeout: TimeInterval = 900
}
