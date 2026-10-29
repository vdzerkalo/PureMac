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

    /// One reclaim action per `docker system df` row, each run as its own
    /// prune so the user can keep, say, images while dropping build cache.
    /// Every action is scoped to what df reports as reclaimable for its row,
    /// which is why images, volumes and build cache use `-a`: without it the
    /// command frees only dangling objects, a fraction of the promised size.
    enum PruneAction: String, CaseIterable {
        case buildCache = "build-cache"
        case stoppedContainers = "containers"
        case unusedImages = "images"
        case unusedVolumes = "volumes"

        /// The `Type` column of the `docker system df` row this action frees.
        var diskUsageType: String {
            switch self {
            case .buildCache: return "Build Cache"
            case .stoppedContainers: return "Containers"
            case .unusedImages: return "Images"
            case .unusedVolumes: return "Local Volumes"
            }
        }

        var arguments: [String] {
            switch self {
            case .buildCache: return ["builder", "prune", "-a", "-f"]
            case .stoppedContainers: return ["container", "prune", "-f"]
            case .unusedImages: return ["image", "prune", "-a", "-f"]
            case .unusedVolumes: return ["volume", "prune", "-a", "-f"]
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

    static func actionPath(for action: PruneAction) -> String {
        actionPathPrefix + action.rawValue
    }

    static func action(forPath path: String) -> PruneAction? {
        guard path.hasPrefix(actionPathPrefix) else { return nil }
        return PruneAction(rawValue: String(path.dropFirst(actionPathPrefix.count)))
    }

    /// Reclaimable bytes per action, in display order, skipping empty rows.
    static func pruneEstimates(_ rows: [DiskUsageRow]) -> [(action: PruneAction, bytes: Int64)] {
        PruneAction.allCases.compactMap { action in
            let bytes = rows
                .filter { $0.type == action.diskUsageType }
                .reduce(0) { $0 + $1.reclaimable }
            return bytes > 0 ? (action, bytes) : nil
        }
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

    /// Docker Desktop's VM disk. It is a sparse file: Finder shows its
    /// maximum size, while the bytes it really occupies are its allocated
    /// size. Prune frees space inside the VM, and Docker Desktop hands it
    /// back to macOS a few minutes later, so this is reported, never deleted.
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
    static func isDaemonUnavailable(stderr: String) -> Bool {
        stderr.contains("Cannot connect") || stderr.contains("dial unix") || stderr.contains("daemon")
    }

    /// A prune of a large build cache can run for minutes; the limit only
    /// exists so a wedged daemon can't hang the clean forever.
    static let pruneTimeout: TimeInterval = 900
}
