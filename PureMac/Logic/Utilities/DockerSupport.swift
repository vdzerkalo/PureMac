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

    /// Bytes `docker system prune -f` can be expected to free, out of the
    /// `system df` rows. Without `-a` and `--volumes`, prune leaves tagged
    /// images and every volume alone, so the Images and Local Volumes
    /// reclaimable figures must not be counted — summing every row promised
    /// space the clean never freed. Dangling images are removed too, but df
    /// has no separate figure for them, so the estimate errs on the low side.
    static func systemPruneEstimate(_ rows: [DiskUsageRow]) -> Int64 {
        rows
            .filter { $0.type == "Containers" || $0.type == "Build Cache" }
            .reduce(0) { $0 + $1.reclaimable }
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

    /// `docker system prune` on a large build cache can run for minutes; the
    /// limit only exists so a wedged daemon can't hang the clean forever.
    static let pruneTimeout: TimeInterval = 900
}
