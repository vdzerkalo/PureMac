import Foundation

/// Pure helpers for the Local AI Models category: Ollama endpoint and listing
/// parsing, Hugging Face hub cache layout, and path validation. No process or
/// network I/O lives here, so unit tests can cover the scan/remove contract
/// against fixture folders without touching a real `ollama` or `hf`.
enum LocalAIModelsSupport {

    // MARK: - Ollama

    struct OllamaModel: Equatable {
        let name: String
        let sizeBytes: Int64
        let modifiedAt: Date?
    }

    struct OllamaEndpoint: Equatable {
        let baseURL: URL
        /// Only loopback servers are managed. A remote `OLLAMA_HOST` would
        /// make "freed space" meaningless and send delete requests to another
        /// machine, so it is reported instead of used.
        let isLoopback: Bool
    }

    static let defaultOllamaPort = 11434

    /// Resolve the server address the way `ollama` does: `OLLAMA_HOST` may be
    /// `host`, `host:port`, `:port`, `http://host`, `https://host:port` or a
    /// bracketed IPv6 literal. Empty and wildcard addresses mean "this Mac".
    /// Returns nil when the value cannot be parsed.
    static func ollamaEndpoint(environment: [String: String]) -> OllamaEndpoint? {
        var value = (environment["OLLAMA_HOST"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme = "http"
        var explicitScheme = false
        let lowered = value.lowercased()
        if lowered.hasPrefix("https://") {
            scheme = "https"
            explicitScheme = true
            value = String(value.dropFirst("https://".count))
        } else if lowered.hasPrefix("http://") {
            explicitScheme = true
            value = String(value.dropFirst("http://".count))
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }

        var host = value
        var port: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":") {
                port = String(rest.dropFirst())
            } else if !rest.isEmpty {
                return nil
            }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            port = String(value[value.index(after: colon)...])
        }

        if host.isEmpty || host == "0.0.0.0" { host = "127.0.0.1" }
        if host == "::" { host = "::1" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        let portNumber: Int
        if let port, !port.isEmpty {
            guard let parsed = Int(port), (1...65535).contains(parsed) else { return nil }
            portNumber = parsed
        } else if explicitScheme {
            portNumber = scheme == "https" ? 443 : 80
        } else {
            portNumber = defaultOllamaPort
        }

        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "\(scheme)://\(bracketed):\(portNumber)") else { return nil }
        return OllamaEndpoint(baseURL: url, isLoopback: isLoopbackHost(host))
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// Model names go to `ollama rm` as one argument and to the API as JSON.
    /// Ollama names look like `qwen3.5:35b`, `library/llama3:8b` or
    /// `hf.co/org/repo:Q4_K_M`. A leading `-` would be read as a flag.
    static func isValidOllamaModelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/@+")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Parse the `GET /api/tags` payload: `{"models":[{"name","size","modified_at"}]}`.
    /// Returns nil when the payload is not that shape. Entries without a size
    /// (Ollama cloud models) are dropped: nothing is stored locally.
    static func parseOllamaTagsJSON(_ data: Data) -> [OllamaModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("models")
        else { return nil }
        if object["models"] is NSNull { return [] }
        guard let entries = object["models"] as? [[String: Any]] else { return nil }
        return entries.compactMap { entry in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { return nil }
            return OllamaModel(
                name: name,
                sizeBytes: size,
                modifiedAt: (entry["modified_at"] as? String).flatMap(parseISODate)
            )
        }
    }

    /// Parse `ollama list` output. Columns are separated by two or more
    /// spaces (`NAME  ID  SIZE  MODIFIED`); sizes use decimal units
    /// ("6.6 GB") and the modified column is relative ("6 months ago"), so
    /// rows from the CLI carry no date.
    static func parseOllamaListTable(_ text: String) -> [OllamaModel] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let columns = line
                .replacingOccurrences(of: #"\s{2,}"#, with: "\t", options: .regularExpression)
                .components(separatedBy: "\t")
            guard columns.count >= 3, columns[0] != "NAME",
                  let size = parseOllamaSize(columns[2]), size > 0
            else { return nil }
            return OllamaModel(name: columns[0], sizeBytes: size, modifiedAt: nil)
        }
    }

    static func parseOllamaSize(_ text: String) -> Int64? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), value >= 0 else { return nil }
        let multiplier: Double
        switch parts[1].uppercased() {
        case "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// Ollama emits Go's RFC 3339 with up to nanosecond precision
    /// ("2025-09-12T10:21:33.123456789+03:00"); the fraction is normalised to
    /// exactly three digits before parsing.
    static func parseISODate(_ raw: String) -> Date? {
        var normalized = raw
        if let range = raw.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = raw[raw.index(after: range.lowerBound)..<range.upperBound]
            let milliseconds = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized.replaceSubrange(range, with: "." + milliseconds)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    // MARK: - Hugging Face locations

    enum HubRepoKind: String, CaseIterable {
        case model
        case dataset
        case space

        var folderPrefix: String { "\(rawValue)s--" }
    }

    /// Entries at the cache root that belong to the hub layout itself, never
    /// to a repo or a user folder.
    static let reservedHubEntries: Set<String> = ["blobs", "refs", "snapshots"]

    /// Hub cache root with the precedence `huggingface_hub` uses:
    /// `HF_HUB_CACHE`, legacy `HUGGINGFACE_HUB_CACHE`, `HF_HOME/hub`,
    /// `XDG_CACHE_HOME/huggingface/hub`, then `~/.cache/huggingface/hub`.
    /// Relative values are ignored: Python would resolve them against a
    /// working directory a GUI app does not have.
    static func hubCachePath(environment: [String: String], homePath: String) -> String {
        func absolute(_ key: String) -> String? {
            guard var value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            if value == "~" || value.hasPrefix("~/") { value = homePath + value.dropFirst() }
            return value.hasPrefix("/") ? (value as NSString).standardizingPath : nil
        }
        if let path = absolute("HF_HUB_CACHE") { return path }
        if let path = absolute("HUGGINGFACE_HUB_CACHE") { return path }
        if let path = absolute("HF_HOME") { return path + "/hub" }
        if let path = absolute("XDG_CACHE_HOME") { return path + "/huggingface/hub" }
        return homePath + "/.cache/huggingface/hub"
    }

    /// Fixed MLX/GGUF model folders some apps keep next to the hub cache.
    /// Not configurable: no environment variable moves them.
    static func appSupportModelRoots(homePath: String) -> [String] {
        let base = homePath + "/Library/Application Support/huggingface"
        return [base + "/models", base + "/gguf_models"]
    }

    /// `models--org--name` -> (.model, "org/name"). The repo id is only
    /// handed to the `hf` CLI when it has the usual one or two segments.
    static func parseHubRepoFolder(_ folder: String) -> (kind: HubRepoKind, repoID: String, cliTarget: String?)? {
        for kind in HubRepoKind.allCases where folder.hasPrefix(kind.folderPrefix) {
            let rest = String(folder.dropFirst(kind.folderPrefix.count))
            guard !rest.isEmpty else { return nil }
            let parts = rest.components(separatedBy: "--")
            let repoID = parts.joined(separator: "/")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            let wellFormed = (1...2).contains(parts.count) && parts.allSatisfy {
                !$0.isEmpty && !$0.hasPrefix("-") && $0.unicodeScalars.allSatisfy(allowed.contains)
            }
            return (kind, repoID, wellFormed ? "\(kind.rawValue)/\(repoID)" : nil)
        }
        return nil
    }

    /// Absolute, with no `.`/`..`/empty components, no trailing slash and no
    /// NUL. Deliberately not `standardizingPath`, which also rewrites
    /// `/private/var` to `/var`.
    static func isNormalizedAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.utf8.contains(0) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// A folder name that may become a row or a removal target at the hub root.
    static func isListableHubEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !reservedHubEntries.contains(name)
            && !name.contains("/") && !name.utf8.contains(0)
    }

    /// The cache root must not be a place the user keeps other things: `/`,
    /// the home folder or any of its ancestors, or a top-level personal
    /// folder. An environment variable pointing there would otherwise turn
    /// every folder inside it into a removable "non-standard cache folder".
    static func isPlausibleHubRoot(_ canonicalRoot: String, canonicalHome: String) -> Bool {
        let components = canonicalRoot.split(separator: "/")
        guard canonicalRoot.hasPrefix("/"), components.count >= 3 else { return false }
        if canonicalRoot == canonicalHome || canonicalHome.hasPrefix(canonicalRoot + "/") { return false }
        let personal = ["Documents", "Desktop", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]
        if (canonicalRoot as NSString).deletingLastPathComponent == canonicalHome,
           personal.contains((canonicalRoot as NSString).lastPathComponent) {
            return false
        }
        return true
    }

    // MARK: - Filesystem inspection (never follows symlinks)

    enum EntryType {
        case file
        case directory
        case symlink
        case other
    }

    struct EntryInfo {
        let type: EntryType
        let size: Int64
        let modified: Date
    }

    /// `lstat` wrapper: describes the entry itself, never its symlink target.
    static func entryInfo(atPath path: String) -> EntryInfo? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let type: EntryType
        switch status.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        let seconds = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return EntryInfo(type: type, size: Int64(status.st_size), modified: Date(timeIntervalSince1970: seconds))
    }

    /// Fully resolved absolute path (`realpath`), or nil when it does not exist.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Bytes of the regular files in a tree. Symlinks are neither followed
    /// nor counted, so a link into another repo never inflates the size.
    static func treeBytes(atPath path: String, fileManager: FileManager = .default) -> Int64 {
        guard let root = entryInfo(atPath: path) else { return 0 }
        if root.type == .file { return root.size }
        guard root.type == .directory else { return 0 }
        var total: Int64 = 0
        var pending = [path]
        while let directory = pending.popLast() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names {
                let full = directory + "/" + name
                guard let info = entryInfo(atPath: full) else { continue }
                switch info.type {
                case .file: total += info.size
                case .directory: pending.append(full)
                case .symlink, .other: break
                }
            }
        }
        return total
    }

    struct HubRepoInspection: Equatable {
        /// Bytes stored inside the repo folder: its own blob files plus any
        /// real (non-link) files in snapshots.
        var storedBytes: Int64 = 0
        var revisionCount = 0
        /// Approximate: newest change among `refs/*` and `snapshots/*`.
        var lastUsed: Date?
        /// True when a link inside the repo resolves anywhere but this repo's
        /// own `blobs/`, for example into a hub-level shared blob store.
        /// Removing such a repo cannot free the linked bytes.
        var linksOutsideRepo = false
        var linkedBytes: Int64 = 0
    }

    /// Inspect one `models--*` / `datasets--*` / `spaces--*` folder.
    /// Returns nil when the path is not a real directory.
    static func inspectHubRepo(atPath path: String, fileManager: FileManager = .default) -> HubRepoInspection? {
        guard let repoInfo = entryInfo(atPath: path), repoInfo.type == .directory,
              let canonicalRepo = canonicalPath(path)
        else { return nil }
        let ownBlobs = canonicalRepo + "/blobs/"
        var result = HubRepoInspection()
        var countedLinkTargets = Set<String>()

        for subtree in ["blobs", "snapshots"] {
            // `contentsOfDirectory` follows a symlinked directory, so a linked
            // subtree is flagged instead of listed.
            if entryInfo(atPath: path + "/" + subtree)?.type == .symlink {
                result.linksOutsideRepo = true
                continue
            }
            var pending = [path + "/" + subtree]
            while let directory = pending.popLast() {
                guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                for name in names {
                    let full = directory + "/" + name
                    guard let info = entryInfo(atPath: full) else { continue }
                    switch info.type {
                    case .file:
                        result.storedBytes += info.size
                    case .directory:
                        pending.append(full)
                    case .symlink:
                        // A snapshot link to this repo's own blob is the normal
                        // layout; the blob itself is counted above.
                        if let target = canonicalPath(full), target.hasPrefix(ownBlobs),
                           entryInfo(atPath: target)?.type == .file {
                            continue
                        }
                        result.linksOutsideRepo = true
                        if let target = canonicalPath(full), countedLinkTargets.insert(target).inserted,
                           let targetInfo = entryInfo(atPath: target), targetInfo.type == .file {
                            result.linkedBytes += targetInfo.size
                        }
                    case .other:
                        break
                    }
                }
            }
        }

        var newest = Date.distantPast
        if entryInfo(atPath: path + "/snapshots")?.type == .directory,
           let revisions = try? fileManager.contentsOfDirectory(atPath: path + "/snapshots") {
            for name in revisions {
                guard let info = entryInfo(atPath: path + "/snapshots/" + name), info.type == .directory else { continue }
                result.revisionCount += 1
                newest = max(newest, info.modified)
            }
        }
        var pendingRefs = entryInfo(atPath: path + "/refs")?.type == .directory ? [path + "/refs"] : []
        while let directory = pendingRefs.popLast() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names {
                let full = directory + "/" + name
                guard let info = entryInfo(atPath: full) else { continue }
                if info.type == .directory { pendingRefs.append(full) }
                if info.type == .file { newest = max(newest, info.modified) }
            }
        }
        result.lastUsed = newest == .distantPast ? repoInfo.modified : newest
        return result
    }
}
