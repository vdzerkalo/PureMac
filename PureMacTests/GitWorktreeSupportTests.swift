import XCTest
@testable import PureMac

final class GitWorktreeSupportTests: XCTestCase {
    private typealias Support = GitWorktreeSupport

    // MARK: - Parsing

    func testParseWorktreeListPorcelain() {
        let output = [
            "worktree /repo", "HEAD aaaa", "branch refs/heads/main", "",
            "worktree /repo/.claude/worktrees/x y", "HEAD bbbb", "branch refs/heads/feature/x", "locked", "",
            "worktree /repo/wt/detached", "HEAD cccc", "detached", "prunable gitdir file points to non-existent location", "",
        ].joined(separator: "\0")

        let listed = Support.parseWorktreeList(output)

        XCTAssertEqual(listed.map(\.path), ["/repo", "/repo/.claude/worktrees/x y", "/repo/wt/detached"])
        XCTAssertEqual(listed[1].branch, "feature/x")
        XCTAssertEqual(listed[1].lockReason, "")
        XCTAssertTrue(listed[1].isLocked)
        XCTAssertTrue(listed[2].isDetached)
        XCTAssertNil(listed[2].branch)
        XCTAssertEqual(listed[2].prunableReason, "gitdir file points to non-existent location")
    }

    func testParseStatusCountsTrackedUntrackedAndIgnored() {
        let output = [
            "1 .M N... 100644 100644 100644 aaaa bbbb Sources/a.swift",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new.swift", "old.swift",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.swift",
            "? notes.md",
            "! .env.local",
            "! node_modules/",
        ].joined(separator: "\0") + "\0"

        let status = Support.parseStatus(output)

        XCTAssertEqual(status.trackedChanges, 3)
        XCTAssertEqual(status.untracked, ["notes.md"])
        XCTAssertEqual(status.ignored, [".env.local", "node_modules/"])
        XCTAssertEqual(status.ignoredEnvFiles, [".env.local"])
    }

    func testStashAttribution() {
        let stashes = "1111 2222\0WIP on feature/x: 1111 wip\0" + "3333\0On other: msg\0"

        XCTAssertTrue(Support.hasAttributedStash(stashes, branch: "feature/x", head: "9999"))
        XCTAssertTrue(Support.hasAttributedStash(stashes, branch: nil, head: "3333"))
        XCTAssertFalse(Support.hasAttributedStash(stashes, branch: "feature", head: "9999"))
        XCTAssertFalse(Support.hasAttributedStash(stashes, branch: "sibling", head: "3333"), "a shared base commit is not ownership")
        XCTAssertFalse(Support.hasAttributedStash("", branch: "feature/x", head: "1111"))
    }

    func testReflogAndCherryHelpers() {
        XCTAssertTrue(Support.reflogShowsOwnWork("commit: add x\nreset: moving to HEAD\n"))
        XCTAssertFalse(Support.reflogShowsOwnWork(""))
        XCTAssertFalse(Support.reflogShowsOwnWork("reset: moving to HEAD\n"))
        XCTAssertTrue(Support.cherryAllApplied("- aaaa\n- bbbb\n"))
        XCTAssertTrue(Support.cherryAllApplied(""))
        XCTAssertFalse(Support.cherryAllApplied("- aaaa\n+ bbbb\n"))
    }

    func testClaudeProjectPathsReadsOnlyProjectKeys() {
        let json = #"{"oauthAccount":{"email":"x"},"projects":{"/b":{"history":[]},"/a":{}}}"#.data(using: .utf8)!
        XCTAssertEqual(Support.claudeProjectPaths(fromClaudeJSON: json), ["/a", "/b"])
        XCTAssertEqual(Support.claudeProjectPaths(fromClaudeJSON: Data()), [])
    }

    func testMainRepositoryFromCommonDir() {
        XCTAssertEqual(Support.mainRepository(forCommonDir: "/Users/x/repo/.git\n"), "/Users/x/repo")
        XCTAssertNil(Support.mainRepository(forCommonDir: "/Users/x/repo.git"))
    }

    func testAgentWorktreePaths() {
        XCTAssertTrue(Support.isAgentWorktreePath("/r/.claude/worktrees/a", homeDirectory: "/Users/t"))
        XCTAssertTrue(Support.isAgentWorktreePath("/Users/t/.cursor/worktrees/r/a", homeDirectory: "/Users/t"))
        XCTAssertTrue(Support.isAgentWorktreePath("/Users/t/.codex/worktrees/a", homeDirectory: "/Users/t"))
        XCTAssertFalse(Support.isAgentWorktreePath("/r/wt/a", homeDirectory: "/Users/t"))
    }

    // MARK: - Classification rules

    func testEarlyProtectedStatusIsFinalWhateverTheSkippedChecksFind() {
        let early: [(String, (inout Support.Signals) -> Void)] = [
            ("tracked", { $0.status.trackedChanges = 1 }),
            ("unique", { $0.uniqueCommits = 2 }),
            ("stash", { $0.hasAttributedStash = true }),
            ("locked", { $0.listed.lockReason = "" }),
            ("inUse", { $0.inUse = true }),
        ]
        // What the skipped steps (ignored-folder walk, merge-base, cherry,
        // reflog) could have reported, in every combination.
        let skipped: [(inout Support.Signals) -> Void] = [
            { $0.nestedRepositoryInIgnored = true },
            { $0.envFilesInIgnoredFolders = 3 },
            { $0.ignoredFoldersNotFullyChecked = true },
            { $0.status.harmlessIgnored = ["vendor/"]; $0.status.ignored = ["vendor/", "notes/"] },
            { $0.isAncestorOfBase = false; $0.cherryAllApplied = false },
            { $0.hadOwnWork = false },
            { $0.baseRef = nil },
        ]
        for (name, apply) in early {
            let base = signals(apply)
            XCTAssertTrue(Support.isProtectedBeforeWalk(base), name)
            for mask in 0..<(1 << skipped.count) {
                var full = base
                for (bit, change) in skipped.enumerated() where mask & (1 << bit) != 0 { change(&full) }
                XCTAssertEqual(Support.classify(full).status, .protected, "\(name), mask \(mask)")
            }
        }
        XCTAssertFalse(Support.isProtectedBeforeWalk(signals { _ in }), "a clean merged worktree is walked")
        XCTAssertFalse(Support.isProtectedBeforeWalk(signals { $0.status.untracked = ["a.txt"] }), "untracked files only need review")
        var prunable = signals { $0.status.trackedChanges = 1 }
        prunable.listed.prunableReason = "gone"
        XCTAssertFalse(Support.isProtectedBeforeWalk(prunable))
    }

    private func signals(_ change: (inout Support.Signals) -> Void) -> Support.Signals {
        var s = Support.Signals(listed: .init(path: "/r/wt/x", head: "aaaa", branch: "x"))
        s.baseRef = "origin/main"
        s.isAncestorOfBase = true
        s.hadOwnWork = true
        s.lastActivity = Date(timeIntervalSinceNow: -30 * 86_400)
        change(&s)
        return s
    }

    func testMergedCleanIdleIsSafe() {
        XCTAssertEqual(Support.classify(signals { _ in }).status, .safeToDelete)
    }

    func testProtectedReasonsWinOverEverythingElse() {
        let verdict = Support.classify(signals {
            $0.status.trackedChanges = 2
            $0.uniqueCommits = 1
            $0.hasAttributedStash = true
            $0.listed.lockReason = ""
            $0.inUse = true
            $0.status.untracked = ["a"]
        })
        XCTAssertEqual(verdict.status, .protected)
        XCTAssertEqual(verdict.reasons, [.trackedChanges(2), .uniqueCommits(1), .stash, .locked, .inUse])
    }

    func testRecentAgentWorktreeIsProtectedButOldOneIsNot() {
        let recent = Support.classify(signals {
            $0.isAgentWorktree = true
            $0.lastActivity = Date(timeIntervalSinceNow: -3_600)
        })
        XCTAssertEqual(recent, .init(status: .protected, reasons: [.recentAgentActivity]))

        let old = Support.classify(signals { $0.isAgentWorktree = true })
        XCTAssertEqual(old.status, .safeToDelete)
    }

    func testHeadEqualsBaseIsNotTreatedAsMerged() {
        let verdict = Support.classify(signals { $0.hadOwnWork = false })
        XCTAssertEqual(verdict, .init(status: .needsReview, reasons: [.noOwnCommits]))
    }

    func testCherryAppliedCountsAsMergedEvenWithoutReflog() {
        let verdict = Support.classify(signals {
            $0.isAncestorOfBase = false
            $0.cherryAllApplied = true
            $0.hadOwnWork = false
        })
        XCTAssertEqual(verdict.status, .safeToDelete)
    }

    func testReviewReasons() {
        XCTAssertEqual(Support.classify(signals { $0.lastActivity = Date(timeIntervalSinceNow: -2 * 86_400) }),
                       .init(status: .needsReview, reasons: [.activeRecently(days: 2)]))
        XCTAssertEqual(Support.classify(signals { $0.isAncestorOfBase = false }).reasons, [.notMerged])
        XCTAssertEqual(Support.classify(signals { $0.baseRef = nil }).reasons, [.noBaseBranch])
        XCTAssertEqual(Support.classify(signals { $0.status.ignored = ["config/.env"] }).reasons, [.envFiles, .ignoredOutsideBuildFolders(1)])
        XCTAssertEqual(Support.classify(signals { $0.status.untracked = ["a", "b"] }).reasons, [.untrackedFiles(2)])
        XCTAssertEqual(Support.classify(signals { $0.lastActivity = nil }).status, .safeToDelete)
    }

    func testPrunableIsOrphan() {
        let verdict = Support.classify(signals { $0.listed.prunableReason = "" ; $0.status.trackedChanges = 5 })
        XCTAssertEqual(verdict, .init(status: .orphan, reasons: [.prunable]))
        XCTAssertTrue(verdict.status.blocksSelection)
        XCTAssertFalse(Support.Status.needsReview.blocksSelection)
    }

    func testOnlyPrunableOrphansCanBeSelected() {
        let prunable = Support.Verdict(status: .orphan, reasons: [.prunable])
        let unknown = Support.Verdict(status: .orphan, reasons: [.notListedByGit])
        let protected = Support.Verdict(status: .protected, reasons: [.locked])
        XCTAssertTrue(prunable.isPrunableOrphan)
        XCTAssertFalse(prunable.blocksSelection)
        XCTAssertFalse(unknown.isPrunableOrphan)
        XCTAssertTrue(unknown.blocksSelection)
        XCTAssertTrue(protected.blocksSelection)
        XCTAssertFalse(Support.Verdict(status: .needsReview, reasons: [.notMerged]).blocksSelection)

        func item(_ verdict: Support.Verdict) -> CleanableItem {
            var item = CleanableItem(name: "x", path: "/r/wt/x", size: 0, category: .gitWorktrees, isSelected: false, lastModified: nil)
            item.gitWorktree = GitWorktreeReport(path: item.path, repositoryPath: "/r", branch: "x", head: nil, verdict: verdict, lastActivity: nil)
            return item
        }
        XCTAssertFalse(item(prunable).isSelectionBlocked)
        XCTAssertTrue(item(unknown).isSelectionBlocked)
        XCTAssertTrue(item(protected).isSelectionBlocked)
    }

    // MARK: - Artifacts, revision names, settings

    func testArtifactDirectoriesComeOnlyFromIgnoredFolders() {
        let ignored = ["node_modules/", "apps/web/.next/", ".env", "docs/build", "cache/", "src/target/", "dist/"]
        XCTAssertEqual(Support.artifactDirectories(inIgnored: ignored), ["node_modules", "apps/web/.next", "src/target", "dist"])
    }

    func testRevisionNamesCannotInjectGitOptions() {
        for good in ["main", "origin/main", "release/1.2", "feature/гілка", "refs/remotes/origin/develop"] {
            XCTAssertTrue(Support.isValidRevisionName(good), good)
        }
        for bad in ["", "-D", "--upload-pack=x", "a b", "a..b", "main^", "x:y", "x@{1}", "a\nb", "/abs", "tail/", "x.lock", "a*", "a[b"] {
            XCTAssertFalse(Support.isValidRevisionName(bad), bad)
        }
    }

    // MARK: - Safety review: ignored work, re-check, base ref

    func testIgnoredEntriesOutsideBuildFoldersNeedReview() {
        let inside = ["node_modules/", "apps/web/.next/", ".venv/", "apps/api/node_modules/x/y.js", "dist/"]
        let outside = ["config/master.key", "secrets/", "vendor/", ".env", "docs/build.txt", "notes/dist"]
        for entry in inside { XCTAssertTrue(Support.isInsideArtifactFolder(entry), entry) }
        for entry in outside { XCTAssertFalse(Support.isInsideArtifactFolder(entry), entry) }

        var status = Support.WorkingTreeStatus()
        status.ignored = inside + outside
        XCTAssertEqual(status.ignoredOutsideBuildFolders, outside)

        let base = signals { _ in }
        XCTAssertEqual(Support.classify(base).status, .safeToDelete)
        let withIgnored = signals { $0.status.ignored = ["config/master.key", "secrets/", "vendor/", "node_modules/"] }
        XCTAssertEqual(Support.classify(withIgnored), .init(status: .needsReview, reasons: [.ignoredOutsideBuildFolders(3)]))
        let onlyBuild = signals { $0.status.ignored = ["node_modules/", "apps/web/.next/"] }
        XCTAssertEqual(Support.classify(onlyBuild).status, .safeToDelete)
    }

    func testMacOSLitterAndHarmlessEntriesDoNotCountAsIgnoredWork() {
        for name in [".DS_Store", "._x", "Icon\r", ".localized"] {
            XCTAssertTrue(Support.isHarmlessIgnoredName(name), name)
        }
        for name in ["._", "notes.txt", ".env", "DS_Store", "Icon", ".DS_Store.bak", "master.key", ".localized2"] {
            XCTAssertFalse(Support.isHarmlessIgnoredName(name), name)
        }
        var status = Support.WorkingTreeStatus()
        status.ignored = [".DS_Store", "docs/.DS_Store", "._x", "a/b/._y", "Icon\r", ".localized", "link", "scratch/"]
        status.harmlessIgnored = ["link", "scratch/"]
        XCTAssertEqual(status.ignoredOutsideBuildFolders, [])
        status.ignored += ["notes.txt", "other/", ".DS_Store/"]
        XCTAssertEqual(status.ignoredOutsideBuildFolders, ["notes.txt", "other/", ".DS_Store/"],
                       "a folder is harmless only when the scanner said so")
        let onlyLitter = signals { $0.status.ignored = [".DS_Store", "._x"] }
        XCTAssertEqual(Support.classify(onlyLitter).status, .safeToDelete)
    }

    func testNestedRepositoryInIgnoredFolderIsProtected() {
        let nested = signals { $0.nestedRepositoryInIgnored = true; $0.status.ignored = ["vendor/"] }
        XCTAssertEqual(Support.classify(nested), .init(status: .protected, reasons: [.nestedRepositoryInIgnored]))
        XCTAssertTrue(Support.classify(nested).blocksSelection)

        let unchecked = signals { $0.ignoredFoldersNotFullyChecked = true }
        XCTAssertEqual(Support.classify(unchecked), .init(status: .needsReview, reasons: [.ignoredFoldersNotFullyChecked]))
        let deepEnv = signals { $0.envFilesInIgnoredFolders = 1 }
        XCTAssertEqual(Support.classify(deepEnv), .init(status: .needsReview, reasons: [.envFiles]))
    }

    func testAWorseVerdictAtRecheckIsDetected() {
        typealias V = Support.Verdict
        let safe = V(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)])
        let review = V(status: .needsReview, reasons: [.untrackedFiles(1), .activeRecently(days: 2)])

        XCTAssertFalse(safe.isWorse(than: safe))
        XCTAssertFalse(V(status: .safeToDelete, reasons: [.mergedAndIdle(days: 40)]).isWorse(than: safe), "a day count alone is not new")
        XCTAssertFalse(review.isWorse(than: review))
        XCTAssertFalse(V(status: .needsReview, reasons: [.untrackedFiles(4)]).isWorse(than: review), "fewer reasons, other counts")
        XCTAssertFalse(safe.isWorse(than: review), "better than scanned is fine")

        XCTAssertTrue(review.isWorse(than: safe))
        XCTAssertTrue(V(status: .protected, reasons: [.trackedChanges(1)]).isWorse(than: review))
        let extended = V(status: .needsReview, reasons: [.untrackedFiles(1), .envFiles])
        XCTAssertTrue(extended.isWorse(than: review), "same status, one more reason")
        XCTAssertEqual(safe.reasonsAdded(since: review), [], "the all-clear reason is never a new problem")
        XCTAssertEqual(extended.reasonsAdded(since: review), [.envFiles])
    }

    func testBaseBranchSettingAcceptsOnlyBranchRefs() {
        XCTAssertEqual(Support.baseRefCandidates(for: "main"), ["refs/heads/main", "refs/remotes/main"])
        XCTAssertEqual(Support.baseRefCandidates(for: " origin/develop "), ["refs/heads/origin/develop", "refs/remotes/origin/develop"])
        XCTAssertEqual(Support.baseRefCandidates(for: "refs/remotes/origin/main"), ["refs/remotes/origin/main"])
        XCTAssertEqual(Support.baseRefCandidates(for: "refs/heads/release/1.2"), ["refs/heads/release/1.2"])
        let rejected = [
            "HEAD", "@", "FETCH_HEAD", "ORIG_HEAD", "MERGE_HEAD", "refs/tags/v1", "refs/stash", "refs/notes/commits",
            "0a1b2c3d", "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567", "-D", "a b", "main~1", "HEAD^", "@{u}", "",
        ]
        for name in rejected { XCTAssertNil(Support.baseRefCandidates(for: name), name) }

        XCTAssertNil(Support.baseBranchSettingProblem(""), "empty means automatic")
        XCTAssertNil(Support.baseBranchSettingProblem("origin/main"))
        XCTAssertNotNil(Support.baseBranchSettingProblem("HEAD"))
        XCTAssertNotNil(Support.baseBranchSettingProblem("@"))
        XCTAssertNotNil(Support.baseBranchSettingProblem("0a1b2c3d"))
    }

    func testBranchNamedByBaseRef() {
        XCTAssertTrue(GitWorktreeScanner.isBranch("dev", namedBy: "refs/heads/dev"))
        XCTAssertTrue(GitWorktreeScanner.isBranch("dev", namedBy: "refs/remotes/origin/dev"))
        XCTAssertTrue(GitWorktreeScanner.isBranch("dev", namedBy: "refs/remotes/upstream/dev"))
        XCTAssertFalse(GitWorktreeScanner.isBranch("dev", namedBy: "refs/remotes/origin/develop"))
        XCTAssertFalse(GitWorktreeScanner.isBranch("dev", namedBy: "refs/heads/feature/dev"))
        XCTAssertFalse(GitWorktreeScanner.isBranch("dev", namedBy: "refs/remotes/dev"))
    }

    func testSettingsReadFromDefaultsAreClampedAndFiltered() throws {
        let suite = "PureMac-WorktreeSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GitWorktreeSettings.current(defaults: defaults), GitWorktreeSettings())
        XCTAssertEqual(GitWorktreeSettings().inactiveDays, Support.defaultInactiveDays)
        XCTAssertFalse(GitWorktreeSettings().deleteMergedBranch, "deleting merged branches is opt-in")

        defaults.set(0, forKey: GitWorktreeSettings.inactiveDaysKey)
        XCTAssertEqual(GitWorktreeSettings.current(defaults: defaults).inactiveDays, 1)
        defaults.set(9_999, forKey: GitWorktreeSettings.inactiveDaysKey)
        XCTAssertEqual(GitWorktreeSettings.current(defaults: defaults).inactiveDays, 365)
        defaults.set(3, forKey: GitWorktreeSettings.inactiveDaysKey)
        defaults.set(["/Users/x/Code", "relative", "/"], forKey: GitWorktreeSettings.extraRootsKey)
        defaults.set("  origin/develop \n", forKey: GitWorktreeSettings.baseBranchKey)
        defaults.set(true, forKey: GitWorktreeSettings.deleteMergedBranchKey)

        XCTAssertEqual(GitWorktreeSettings.current(defaults: defaults), GitWorktreeSettings(
            inactiveDays: 3, extraRoots: ["/Users/x/Code"], baseBranch: "origin/develop", deleteMergedBranch: true))
    }

    func testUnmountedVolumeIsRecognised() {
        let missing = "/Volumes/PureMac-not-mounted-\(UUID().uuidString)"
        XCTAssertEqual(GitWorktreeScanner.unmountedVolume(of: missing + "/repo/wt/x"), missing)
        XCTAssertNil(GitWorktreeScanner.unmountedVolume(of: "/Users/t/repo/wt/x"))
        XCTAssertNil(GitWorktreeScanner.unmountedVolume(of: "/Volumes"))
    }

    /// The artifact list must stay a subset of the CLI's `Purger.artifactNames`
    /// plus the documented extras, so the app and `puremac clean dev` agree
    /// on what a build artifact is.
    func testArtifactNamesMatchTheCommandLineTool() throws {
        let purger = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/Sources/puremac/Core/Purger.swift")
        let source = try String(contentsOf: purger, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "artifactNames: Set<String> = ["))
        let list = try XCTUnwrap(source[start.upperBound...].range(of: "]"))
        let block = source[start.upperBound..<list.lowerBound]
        let names = Set(block.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) })
        XCTAssertFalse(names.isEmpty, "could not read Purger.artifactNames")

        let missing = Support.artifactDirectoryNames.subtracting(names).subtracting(Support.artifactNamesOnlyHere)
        XCTAssertEqual(missing, [], "add these to Purger.artifactNames or to GitWorktreeSupport.artifactNamesOnlyHere")
        XCTAssertTrue(Support.artifactNamesOnlyHere.isSubset(of: Support.artifactDirectoryNames))
    }

    func testLocateGitAvoidsShimWithoutDeveloperTools() {
        XCTAssertEqual(GitWorktreeScanner.locateGit(isExecutable: { $0 == "/opt/homebrew/bin/git" }, developerToolsInstalled: { false }),
                       "/opt/homebrew/bin/git")
        XCTAssertNil(GitWorktreeScanner.locateGit(isExecutable: { $0 == "/usr/bin/git" }, developerToolsInstalled: { false }))
        XCTAssertEqual(GitWorktreeScanner.locateGit(isExecutable: { $0 == "/usr/bin/git" }, developerToolsInstalled: { true }),
                       "/usr/bin/git")
    }
}

// MARK: - Real repositories in $TMPDIR

final class GitWorktreeScannerTests: XCTestCase {
    private var root: URL!
    private var repo: String!
    private var gitPath: String!
    private let oldDate = "2026-01-01T12:00:00+0000"

    override func setUpWithError() throws {
        gitPath = try XCTUnwrap(GitWorktreeScanner.locateGit(), "git is required for these tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PureMac-Worktrees-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin.git").path
        repo = GitWorktreeScanner.canonical(root.path) + "/repo"
        try git(["init", "--bare", "-q", "-b", "main", origin], in: root.path)
        try git(["clone", "-q", origin, repo], in: root.path)
        try write(".env\nnode_modules/\nlink-out\n", to: "\(repo!)/.gitignore")
        try write("hello\n", to: "\(repo!)/README.md")
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)
        try git(["remote", "set-head", "origin", "-a"], in: repo)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Fixture helpers

    @discardableResult
    private func git(_ args: [String], in dir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", dir, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                             "-c", "commit.gpgsign=false", "-c", "advice.detachedHead=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_DATE"] = oldDate
        env["GIT_COMMITTER_DATE"] = oldDate
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(String(data: errData, encoding: .utf8) ?? "")",
            ])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// New worktree on a new branch from main, at `relative` inside the repo.
    @discardableResult
    private func addWorktree(_ relative: String, branch: String) throws -> String {
        let path = "\(repo!)/\(relative)"
        try git(["worktree", "add", "-q", "-b", branch, path, "main"], in: repo)
        return path
    }

    private func commit(in path: String, file: String, _ text: String = UUID().uuidString) throws {
        try write(text + "\n", to: "\(path)/\(file)")
        try git(["add", file], in: path)
        try git(["commit", "-q", "-m", "change \(file)"], in: path)
    }

    /// Fast-forward main to `branch` and push, so the branch is merged.
    private func mergeIntoMain(_ branch: String) throws {
        try git(["merge", "-q", "--ff-only", branch], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)
    }

    /// Backdate every file, folder and git admin file of a worktree.
    private func age(_ path: String, days: Double = 30) throws {
        let date = Date(timeIntervalSinceNow: -days * 86_400)
        var paths = [path]
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let child as String in enumerator { paths.append("\(path)/\(child)") }
        }
        let gitFile = try String(contentsOfFile: "\(path)/.git", encoding: .utf8)
        let admin = gitFile.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        paths.append(admin)
        if let enumerator = FileManager.default.enumerator(atPath: admin) {
            for case let child as String in enumerator { paths.append("\(admin)/\(child)") }
        }
        for item in paths {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item)
        }
    }

    private func scanner(inUse: [String] = []) -> GitWorktreeScanner {
        var scanner = GitWorktreeScanner(homeDirectory: root.path, gitPath: gitPath)
        scanner.repositoryHints = [repo]
        scanner.workingDirectories = { inUse }
        return scanner
    }

    private func verdicts(_ reports: [GitWorktreeReport]) -> [String: GitWorktreeSupport.Verdict] {
        Dictionary(uniqueKeysWithValues: reports.map { (GitWorktreeScanner.canonical($0.path), $0.verdict) })
    }

    // MARK: Tests

    func testClassifiesEveryKindOfWorktree() async throws {
        let mergedOld = try addWorktree("wt/merged-old", branch: "merged-old")
        try commit(in: mergedOld, file: "a.txt")
        try mergeIntoMain("merged-old")

        let mergedFresh = try addWorktree("wt/merged-fresh", branch: "merged-fresh")
        try commit(in: mergedFresh, file: "b.txt")
        try mergeIntoMain("merged-fresh")

        let headIsBase = try addWorktree("wt/head-is-base", branch: "head-is-base")

        let dirty = try addWorktree("wt/dirty", branch: "dirty")
        try write("changed\n", to: "\(dirty)/README.md")

        let untracked = try addWorktree("wt/untracked", branch: "untracked")
        try commit(in: untracked, file: "u.txt")
        try mergeIntoMain("untracked")
        try write("notes\n", to: "\(untracked)/notes.md")

        let unpushed = try addWorktree("wt/unpushed", branch: "unpushed")
        try commit(in: unpushed, file: "local-only.txt")

        let stashed = try addWorktree("wt/stashed", branch: "stashed")
        try write("wip\n", to: "\(stashed)/README.md")
        try git(["stash", "push", "-q", "-m", "wip"], in: stashed)

        let locked = try addWorktree("wt/locked", branch: "locked")
        try git(["worktree", "lock", "--reason", "agent", locked], in: repo)

        let rebased = try addWorktree("wt/rebased", branch: "rebased")
        try write("x\n", to: "\(repo!)/main-only.txt")
        try git(["add", "main-only.txt"], in: repo)
        try git(["commit", "-q", "-m", "main moves on"], in: repo)
        try commit(in: rebased, file: "r.txt", "rebased change")
        try git(["push", "-q", "origin", "rebased"], in: rebased)
        let rebasedSha = try git(["rev-parse", "HEAD"], in: rebased).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["cherry-pick", rebasedSha], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)

        let squashed = try addWorktree("wt/squashed", branch: "squashed")
        try commit(in: squashed, file: "s1.txt")
        try commit(in: squashed, file: "s2.txt")
        try git(["push", "-q", "origin", "squashed"], in: squashed)
        try git(["merge", "-q", "--squash", "squashed"], in: repo)
        try git(["commit", "-q", "-m", "squash"], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)

        let envFile = try addWorktree("wt/env", branch: "env")
        try commit(in: envFile, file: "e.txt")
        try git(["merge", "-q", "env"], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)
        try write("SECRET=1\n", to: "\(envFile)/.env")

        let unicode = try addWorktree("wt/гілка з пробілом", branch: "unicode")
        try commit(in: unicode, file: "u8.txt")
        try git(["merge", "-q", "unicode"], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)

        let inUse = try addWorktree("wt/in-use", branch: "in-use")

        let agentRecent = try addWorktree(".claude/worktrees/agent-recent", branch: "agent-recent")
        try commit(in: agentRecent, file: "ar.txt")
        try git(["merge", "-q", "agent-recent"], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)

        let agentOld = try addWorktree(".claude/worktrees/agent-old", branch: "agent-old")
        try commit(in: agentOld, file: "ao.txt")
        try git(["merge", "-q", "agent-old"], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)

        let prunable = try addWorktree("wt/prunable", branch: "prunable")
        try FileManager.default.removeItem(atPath: prunable)

        let ghost = "\(repo!)/.claude/worktrees/ghost"
        try write("gitdir: /nonexistent/worktrees/ghost\n", to: "\(ghost)/.git")

        for path in [mergedOld, headIsBase, dirty, untracked, unpushed, stashed, locked, rebased, squashed, envFile, unicode, inUse, agentOld] {
            try age(path)
        }

        let reports = await scanner(inUse: ["\(inUse)/Sources"]).scan()
        let byPath = verdicts(reports)
        func verdict(_ path: String) -> GitWorktreeSupport.Verdict? { byPath[GitWorktreeScanner.canonical(path)] ?? byPath[path] }

        XCTAssertNil(byPath[GitWorktreeScanner.canonical(repo)], "the main worktree is never a candidate")
        XCTAssertEqual(verdict(mergedOld)?.status, .safeToDelete)
        XCTAssertEqual(verdict(mergedFresh)?.status, .needsReview)
        XCTAssertEqual(verdict(mergedFresh)?.reasons.first, .activeRecently(days: 0))
        XCTAssertEqual(verdict(headIsBase), .init(status: .needsReview, reasons: [.noOwnCommits]))
        XCTAssertEqual(verdict(dirty), .init(status: .protected, reasons: [.trackedChanges(1)]))
        XCTAssertEqual(verdict(untracked), .init(status: .needsReview, reasons: [.untrackedFiles(1)]))
        XCTAssertEqual(verdict(unpushed), .init(status: .protected, reasons: [.uniqueCommits(1)]))
        XCTAssertEqual(verdict(stashed), .init(status: .protected, reasons: [.stash]))
        XCTAssertEqual(verdict(locked), .init(status: .protected, reasons: [.locked]))
        XCTAssertEqual(verdict(rebased)?.status, .safeToDelete, "a cherry-picked/rebased branch counts as merged")
        XCTAssertEqual(verdict(squashed), .init(status: .needsReview, reasons: [.notMerged]))
        XCTAssertEqual(verdict(envFile), .init(status: .needsReview, reasons: [.envFiles, .ignoredOutsideBuildFolders(1)]))
        XCTAssertEqual(verdict(unicode)?.status, .safeToDelete)
        XCTAssertEqual(verdict(inUse), .init(status: .protected, reasons: [.inUse]))
        XCTAssertEqual(verdict(agentRecent), .init(status: .protected, reasons: [.recentAgentActivity]))
        XCTAssertEqual(verdict(agentOld)?.status, .safeToDelete)
        XCTAssertEqual(verdict(prunable), .init(status: .orphan, reasons: [.prunable]))
        XCTAssertEqual(verdict(ghost), .init(status: .orphan, reasons: [.notListedByGit]))
        XCTAssertEqual(reports.count, 17)
    }

    func testRemoveDeletesOnlyTheWorktreeAndLeavesClaudeConfigAlone() async throws {
        let settings = "\(repo!)/.claude/settings.json"
        let skill = "\(repo!)/.claude/skills/review.md"
        try write(#"{"permissions":{}}"#, to: settings)
        try write("# skill\n", to: skill)
        let done = try addWorktree(".claude/worktrees/done", branch: "done")
        try commit(in: done, file: "d.txt")
        try mergeIntoMain("done")
        try age(done)
        let settingsBefore = try Data(contentsOf: URL(fileURLWithPath: settings))

        let scanner = scanner()
        let inspected = await scanner.reinspect(path: done, repository: repo)
        let report = try XCTUnwrap(inspected)
        XCTAssertEqual(report.verdict.status, .safeToDelete)

        let error = await scanner.remove(path: done, repository: repo)

        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: done))
        XCTAssertFalse(try git(["worktree", "list", "--porcelain"], in: repo).contains("/done"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settings)), settingsBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill))
        XCTAssertTrue(try git(["branch", "--list", "done"], in: repo).contains("done"), "the branch is kept")
        let reinspected = await scanner.reinspect(path: done, repository: repo)
        XCTAssertNil(reinspected)
    }

    func testGitRefusesDirtyWorktreeAndReportsWhy() async throws {
        let dirty = try addWorktree("wt/dirty", branch: "dirty")
        try write("changed\n", to: "\(dirty)/README.md")

        let error = await scanner().remove(path: dirty, repository: repo)

        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dirty)/README.md"))
    }

    func testCleaningEngineRechecksBeforeRemoving() async throws {
        let worktree = try addWorktree("wt/changes-after-scan", branch: "changes-after-scan")
        try commit(in: worktree, file: "c.txt")
        try mergeIntoMain("changes-after-scan")
        try age(worktree)
        let inspected = await scanner().reinspect(path: worktree, repository: repo)
        let report = try XCTUnwrap(inspected)
        XCTAssertEqual(report.verdict.status, .safeToDelete)
        var item = CleanableItem(
            name: report.displayName,
            path: worktree,
            size: 1_000,
            category: .gitWorktrees,
            isSelected: true,
            lastModified: report.lastActivity
        )
        item.gitWorktree = report

        // An agent starts editing between the scan and the clean.
        try write("edited after scan\n", to: "\(worktree)/README.md")
        let engine = CleaningEngine(homeDirectory: root)
        let blocked = await engine.cleanItems([item]) { _ in }

        XCTAssertEqual(blocked.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(blocked.errors.contains { $0.contains("Protected") }, "\(blocked.errors)")

        // Once the edit is gone (and the folder has been quiet again) the same item is removed.
        try git(["checkout", "--", "README.md"], in: worktree)
        try age(worktree)
        let cleaned = await engine.cleanItems([item]) { _ in }
        XCTAssertEqual(cleaned.itemsCleaned, 1, "\(cleaned.errors)")
        XCTAssertEqual(cleaned.freedSpace, 1_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    func testWorktreeInCloudProviderStorageIsNotRemoved() async throws {
        // A `com~apple~` component marks iCloud state wherever it appears,
        // which stands in for a repository under ~/Library/Mobile Documents.
        let worktree = try addWorktree("com~apple~CloudDocs/synced", branch: "synced")
        try commit(in: worktree, file: "s.txt")
        try mergeIntoMain("synced")
        try age(worktree)
        let inspected = await scanner().reinspect(path: worktree, repository: repo)
        let report = try XCTUnwrap(inspected)
        XCTAssertEqual(report.verdict.status, .safeToDelete)
        var item = CleanableItem(
            name: report.displayName,
            path: worktree,
            size: 1_000,
            category: .gitWorktrees,
            isSelected: true,
            lastModified: report.lastActivity
        )
        item.gitWorktree = report

        let result = await CleaningEngine(homeDirectory: root).cleanItems([item]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(worktree)/s.txt"))
        XCTAssertTrue(result.errors.contains { $0.contains("cloud-synced") }, "\(result.errors)")
    }

    // MARK: Polish: symlinks, sizes, settings, branches, prune

    private func item(for report: GitWorktreeReport, size: Int64 = 1_000) -> CleanableItem {
        var item = CleanableItem(
            name: report.displayName,
            path: report.path,
            size: size,
            category: .gitWorktrees,
            isSelected: false,
            lastModified: report.lastActivity
        )
        item.gitWorktree = report
        return item
    }

    private func inspect(_ path: String, with scanner: GitWorktreeScanner? = nil) async throws -> GitWorktreeReport {
        let report = await (scanner ?? self.scanner()).reinspect(path: path, repository: repo)
        return try XCTUnwrap(report)
    }

    private func engine(_ settings: GitWorktreeSettings = GitWorktreeSettings()) -> CleaningEngine {
        CleaningEngine(homeDirectory: root, worktreeSettings: { settings })
    }

    /// A merged, old, clean worktree (Safe to delete with default settings).
    private func makeMerged(_ name: String, days: Double = 30) throws -> String {
        let path = try addWorktree("wt/\(name)", branch: name)
        try commit(in: path, file: "\(name).txt")
        try mergeIntoMain(name)
        try age(path, days: days)
        return path
    }

    func testSymlinkInsideWorktreeIsNeitherFollowedNorCounted() async throws {
        let outside = root.appendingPathComponent("outside").path
        try write(String(repeating: "precious ", count: 100_000), to: "\(outside)/precious.txt")
        let outsideBefore = try Data(contentsOf: URL(fileURLWithPath: "\(outside)/precious.txt"))

        let worktree = try makeMerged("with-link")
        try write(String(repeating: "x", count: 300_000), to: "\(worktree)/node_modules/pkg/index.js")
        try FileManager.default.createSymbolicLink(atPath: "\(worktree)/link-out", withDestinationPath: outside)
        // A symlink named like an artifact folder must not be followed either.
        try FileManager.default.createSymbolicLink(atPath: "\(worktree)/dist", withDestinationPath: outside)
        try age(worktree)
        for link in ["link-out", "dist"] {
            let touch = Process()
            touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            touch.arguments = ["-h", "-t", "202601011200", "\(worktree)/\(link)"]
            try touch.run()
            touch.waitUntilExit()
        }

        let report = try await inspect(worktree)
        XCTAssertEqual(report.artifactDirectories, ["node_modules"])
        let sizes = GitWorktreeScanner.measure(path: worktree, artifactDirectories: report.artifactDirectories)
        XCTAssertGreaterThanOrEqual(sizes.artifacts, 300_000)
        XCTAssertLessThan(sizes.artifacts, 400_000, "only node_modules counts as artifacts")
        XCTAssertLessThan(sizes.code, 100_000, "the 900 KB file behind the symlinks is not counted")
        let direct = GitWorktreeScanner.allocatedBytes(under: URL(fileURLWithPath: worktree))
        XCTAssertLessThan(direct, 500_000)

        // The untracked `dist` symlink is a review reason, the ignored one is not.
        XCTAssertEqual(report.verdict, .init(status: .needsReview, reasons: [.untrackedFiles(1)]))
        try FileManager.default.removeItem(atPath: "\(worktree)/dist")
        try age(worktree)

        let fresh = try await inspect(worktree)
        XCTAssertEqual(fresh.verdict.status, .safeToDelete, "an ignored symlink to elsewhere is no reason to keep a worktree")
        let error = await scanner().remove(path: worktree, repository: repo)

        XCTAssertNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outside)/precious.txt"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(outside)/precious.txt")), outsideBefore)
    }

    func testSizeBreakdownSplitsIgnoredArtifactsFromCode() async throws {
        let worktree = try makeMerged("sizes")
        try write(String(repeating: "c", count: 50_000), to: "\(worktree)/src/code.swift")
        try write(String(repeating: "n", count: 200_000), to: "\(worktree)/node_modules/a/index.js")
        try write(String(repeating: "n", count: 100_000), to: "\(worktree)/app/node_modules/b/index.js")
        // `build` here is neither ignored nor tracked by git, so it is code.
        try write(String(repeating: "b", count: 80_000), to: "\(worktree)/build/out.bin")

        let report = try await inspect(worktree)
        XCTAssertEqual(Set(report.artifactDirectories), ["node_modules", "app/node_modules"])
        let sizes = GitWorktreeScanner.measure(path: worktree, artifactDirectories: report.artifactDirectories)

        XCTAssertGreaterThanOrEqual(sizes.artifacts, 300_000)
        XCTAssertLessThan(sizes.artifacts, 340_000)
        XCTAssertGreaterThanOrEqual(sizes.code, 130_000, "src + untracked build + the checked-out files")
        XCTAssertLessThan(sizes.code, 200_000)

        var measured = report
        measured.artifactBytes = sizes.artifacts
        measured.codeBytes = sizes.code
        let text = try XCTUnwrap(measured.sizeBreakdownText)
        XCTAssertTrue(text.contains(" · "), text)
        XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: sizes.artifacts, countStyle: .file)), text)
        XCTAssertTrue(text.contains(ByteCountFormatter.string(fromByteCount: sizes.code, countStyle: .file)), text)
        XCTAssertNil(report.sizeBreakdownText, "no breakdown before the scan measured it")
        measured.artifactBytes = 0
        XCTAssertEqual(measured.sizeBreakdownText, String(localized: "no build folders · code \(ByteCountFormatter.string(fromByteCount: sizes.code, countStyle: .file))"))
        XCTAssertFalse(measured.sizeBreakdownText?.contains("Zero") ?? true)
    }

    func testProtectedWorktreeIsNotWalkedButAMergedOneStillIs() async throws {
        // Both hide a nested repository in an ignored folder; only the
        // walk finds it.
        let dirty = try makeMerged("early-dirty")
        try git(["init", "-q", "\(dirty)/node_modules/pkg"], in: dirty)
        try write("edit\n", to: "\(dirty)/README.md")
        let clean = try makeMerged("early-clean")
        try git(["init", "-q", "\(clean)/node_modules/pkg"], in: clean)

        let dirtyVerdict = try await inspect(dirty).verdict
        let cleanVerdict = try await inspect(clean).verdict
        XCTAssertEqual(dirtyVerdict.status, .protected)
        XCTAssertEqual(dirtyVerdict.reasons, [.trackedChanges(1)], "git's reason alone; the walk was skipped")
        XCTAssertEqual(cleanVerdict, .init(status: .protected, reasons: [.nestedRepositoryInIgnored]))
    }

    func testParallelScanKeepsOrderReportsProgressAndMeasures() async throws {
        var made: [String] = []
        for index in 0..<(GitWorktreeScanner.concurrentInspections * 2 + 1) {
            let path = try makeMerged("parallel-\(index)")
            try write(String(repeating: "n", count: 40_000), to: "\(path)/node_modules/a/index.js")
            try age(path)
            made.append(GitWorktreeScanner.canonical(path))
        }
        final class Steps: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [GitWorktreeScanner.Progress] = []
            func add(_ step: GitWorktreeScanner.Progress) { lock.lock(); list.append(step); lock.unlock() }
            var all: [GitWorktreeScanner.Progress] { lock.lock(); defer { lock.unlock() }; return list }
        }
        let steps = Steps()
        var measuring = scanner()
        measuring.measuresSizes = true

        let reports = await measuring.scan { steps.add($0) }

        XCTAssertEqual(reports.map { GitWorktreeScanner.canonical($0.path) }, made, "git's order, not completion order")
        XCTAssertTrue(reports.allSatisfy { $0.verdict.status == .safeToDelete })
        XCTAssertTrue(reports.allSatisfy { $0.artifactBytes >= 40_000 && $0.codeBytes > 0 }, "sizes are measured in the same pass")
        let positions = steps.all.compactMap { step -> Int? in
            guard case .inspecting(_, let position, let total) = step else { return nil }
            XCTAssertEqual(total, made.count)
            return position
        }
        XCTAssertEqual(positions.sorted(), Array(1...made.count))
        XCTAssertTrue(steps.all.contains(.discovering(path: repo)))

        let unmeasured = await scanner().scan()
        XCTAssertEqual(unmeasured.map(\.verdict), reports.map(\.verdict))
        XCTAssertTrue(unmeasured.allSatisfy { $0.totalBytes == 0 }, "tests that only need verdicts skip the size walk")
    }

    func testInactiveDaysSettingIsHonoured() async throws {
        let worktree = try makeMerged("three-days", days: 3)

        var sevenDays = scanner()
        sevenDays.inactiveDays = 7
        let tooRecent = try await inspect(worktree, with: sevenDays)
        XCTAssertEqual(tooRecent.verdict, .init(status: .needsReview, reasons: [.activeRecently(days: 3)]))

        var twoDays = scanner()
        twoDays.inactiveDays = 2
        let idle = try await inspect(worktree, with: twoDays)
        XCTAssertEqual(idle.verdict.status, .safeToDelete)

        var tenDays = scanner()
        tenDays.inactiveDays = 10
        let waiting = try await inspect(worktree, with: tenDays)
        XCTAssertEqual(waiting.verdict.status, .needsReview)
    }

    func testBaseBranchOverrideIsHonoured() async throws {
        let worktree = try makeMerged("merged-later")
        // `release` stays on the initial commit, so nothing merged later is in it.
        let initial = try git(["rev-list", "--max-parents=0", "main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["branch", "release", initial], in: repo)

        let auto = try await inspect(worktree)
        XCTAssertEqual(auto.verdict.status, .safeToDelete)

        var toRelease = scanner()
        toRelease.baseBranchOverride = "release"
        let notInRelease = try await inspect(worktree, with: toRelease)
        XCTAssertEqual(notInRelease.verdict, .init(status: .needsReview, reasons: [.notMerged]))

        var toOriginMain = scanner()
        toOriginMain.baseBranchOverride = "origin/main"
        let inMain = try await inspect(worktree, with: toOriginMain)
        XCTAssertEqual(inMain.verdict.status, .safeToDelete)

        for unusable in ["does-not-exist", "-D", "--output=/tmp/x", "a b"] {
            var broken = scanner()
            broken.baseBranchOverride = unusable
            let noBase = try await inspect(worktree, with: broken)
            XCTAssertEqual(noBase.verdict, .init(status: .needsReview, reasons: [.noBaseBranch]), unusable)
        }
    }

    func testExtraRootsAreSearchedForRepositories() async throws {
        let worktree = try makeMerged("found-via-root")
        let nested = root.appendingPathComponent("code/deep/er/est/too-deep").path
        try git(["init", "-q", nested], in: root.path)
        try FileManager.default.createDirectory(atPath: "\(root.path)/code/node_modules/skipped/.git", withIntermediateDirectories: true)

        let found = GitWorktreeScanner.repositoryFolders(under: [root.path, "relative", "/", root.appendingPathComponent("missing").path])
            .map(GitWorktreeScanner.canonical)
        XCTAssertTrue(found.contains(repo), "\(found)")
        XCTAssertFalse(found.contains(where: { $0.hasSuffix("too-deep") || $0.contains("node_modules") }), "\(found)")
        XCTAssertFalse(found.contains(where: { $0.hasSuffix("origin.git") }), "a bare repository has no .git entry")
        XCTAssertFalse(found.contains(where: { $0.hasPrefix(repo + "/") }), "the inside of a repository is not walked")

        var viaRoot = GitWorktreeScanner(homeDirectory: root.path, gitPath: gitPath)
        viaRoot.workingDirectories = { [] }
        viaRoot.extraRoots = [root.path]
        let reports = await viaRoot.scan()
        XCTAssertEqual(verdicts(reports)[GitWorktreeScanner.canonical(worktree)]?.status, .safeToDelete)

        var withoutRoots = GitWorktreeScanner(homeDirectory: root.path, gitPath: gitPath)
        withoutRoots.workingDirectories = { [] }
        let none = await withoutRoots.scan()
        XCTAssertTrue(none.isEmpty, "without hints or roots nothing outside the agent folders is looked at")
    }

    func testRemovalNoLongerPrunesOtherMissingWorktrees() async throws {
        let missing = try addWorktree("wt/missing", branch: "missing")
        try FileManager.default.removeItem(atPath: missing)
        let done = try makeMerged("remove-me")

        let error = await scanner().remove(path: done, repository: repo)

        XCTAssertNil(error)
        XCTAssertTrue(try git(["worktree", "list", "--porcelain"], in: repo).contains("/wt/missing"),
                      "removing one worktree must not forget a missing one nobody selected")
    }

    // MARK: Branch deletion

    func testMergedBranchIsDeletedOnlyWhenEnabledAndSafe() async throws {
        let merged = try makeMerged("branch-merged")
        let report = try await inspect(merged)
        XCTAssertEqual(report.verdict.status, .safeToDelete)

        // Toggle off: the branch stays.
        let off = await engine().cleanItems([item(for: report)]) { _ in }
        XCTAssertEqual(off.itemsCleaned, 1, "\(off.errors)")
        XCTAssertTrue(try git(["branch", "--list", "branch-merged"], in: repo).contains("branch-merged"))
        XCTAssertTrue(off.notes.isEmpty)

        // Toggle on: the same kind of worktree loses its merged branch.
        let second = try makeMerged("branch-merged-2")
        let secondReport = try await inspect(second)
        let on = await engine(GitWorktreeSettings(deleteMergedBranch: true)).cleanItems([item(for: secondReport)]) { _ in }
        XCTAssertEqual(on.itemsCleaned, 1, "\(on.errors)")
        XCTAssertTrue(on.notes.isEmpty, "\(on.notes)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second))
        XCTAssertEqual(try git(["branch", "--list", "branch-merged-2"], in: repo), "")
    }

    func testBranchIsKeptWhenWorktreeWasNotSafeToDelete() async throws {
        // Pushed but not merged: removable by git, verdict Needs review.
        let path = try addWorktree("wt/pushed-only", branch: "pushed-only")
        try commit(in: path, file: "p.txt")
        try git(["push", "-q", "origin", "pushed-only"], in: path)
        try age(path)
        let report = try await inspect(path)
        XCTAssertEqual(report.verdict, .init(status: .needsReview, reasons: [.notMerged]))

        let result = await engine(GitWorktreeSettings(deleteMergedBranch: true)).cleanItems([item(for: report)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try git(["branch", "--list", "pushed-only"], in: repo).contains("pushed-only"))
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testGitDecidesWhetherTheBranchIsMerged() async throws {
        // Cherry-picked into main: Safe to delete for PureMac, but not an
        // ancestor of main, so `git branch -d` refuses. The removal still counts.
        let path = try addWorktree("wt/cherried", branch: "cherried")
        try commit(in: path, file: "ch.txt", "cherry content")
        try git(["push", "-q", "origin", "cherried"], in: path)
        let sha = try git(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("x\n", to: "\(repo!)/main-moves.txt")
        try git(["add", "main-moves.txt"], in: repo)
        try git(["commit", "-q", "-m", "main moves"], in: repo)
        try git(["cherry-pick", sha], in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)
        try age(path)
        let report = try await inspect(path)
        XCTAssertEqual(report.verdict.status, .safeToDelete)

        let result = await engine(GitWorktreeSettings(deleteMergedBranch: true)).cleanItems([item(for: report)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertTrue(result.errors.isEmpty, "a refused branch is a note, not an error")
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes.first?.contains("branch cherried kept") == true, "\(result.notes)")
        XCTAssertTrue(try git(["branch", "--list", "cherried"], in: repo).contains("cherried"))
    }

    func testBranchCheckedOutElsewhereOrBaseBranchIsNeverDeleted() async throws {
        let first = try makeMerged("shared-branch")
        let safe = try await inspect(first)
        XCTAssertEqual(safe.verdict.status, .safeToDelete)
        let removal = await scanner().remove(path: first, repository: repo)
        XCTAssertNil(removal)
        // Another worktree checks the same branch out.
        try git(["worktree", "add", "-q", "\(repo!)/wt/second-holder", "shared-branch"], in: repo)

        let heldNote = await scanner().deleteMergedBranch(of: safe, repository: repo)
        XCTAssertTrue(heldNote?.contains("checked out in") == true, "\(heldNote ?? "")")
        XCTAssertTrue(try git(["branch", "--list", "shared-branch"], in: repo).contains("shared-branch"))

        // Not Safe to delete: refused before git is asked.
        let review = GitWorktreeReport(path: first, repositoryPath: repo, branch: "shared-branch", head: nil,
                                       verdict: .init(status: .needsReview, reasons: [.notMerged]), lastActivity: nil)
        let reviewNote = await scanner().deleteMergedBranch(of: review, repository: repo)
        XCTAssertNotNil(reviewNote)

        // The base branch, even when nothing has it checked out.
        try git(["checkout", "-q", "-b", "parking"], in: repo)
        let onMain = GitWorktreeReport(path: first, repositoryPath: repo, branch: "main", head: nil,
                                       verdict: .init(status: .safeToDelete, reasons: []), lastActivity: nil)
        let baseNote = await scanner().deleteMergedBranch(of: onMain, repository: repo)
        XCTAssertTrue(baseNote?.contains("base branch") == true, "\(baseNote ?? "")")
        XCTAssertTrue(try git(["branch", "--list", "main"], in: repo).contains("main"))
    }

    // MARK: Prune

    func testPrunableOrphanIsPrunedThroughTheEngine() async throws {
        let gone = try addWorktree("wt/gone", branch: "gone")
        let bystander = try addWorktree("wt/bystander", branch: "bystander")
        try age(bystander)
        try FileManager.default.removeItem(atPath: gone)
        let report = try await inspect(gone)
        XCTAssertTrue(report.verdict.isPrunableOrphan)
        let row = item(for: report, size: 0)
        XCTAssertFalse(row.isSelectionBlocked)
        XCTAssertFalse(row.isSelected, "never preselected")
        let adminDirs = try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees")
        XCTAssertEqual(Set(adminDirs), ["gone", "bystander"])

        let result = await engine().cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.cleanedPaths.contains(gone))
        XCTAssertFalse(try git(["worktree", "list", "--porcelain"], in: repo).contains("/wt/gone"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees"), ["bystander"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(bystander)/README.md"), "a live worktree is untouched")
        XCTAssertTrue(try git(["branch", "--list", "gone"], in: repo).contains("gone"), "prune keeps the branch")
    }

    func testPruneIsRefusedWhenTheFolderReappeared() async throws {
        let gone = try addWorktree("wt/comes-back", branch: "comes-back")
        try FileManager.default.removeItem(atPath: gone)
        let report = try await inspect(gone)
        XCTAssertTrue(report.verdict.isPrunableOrphan)

        // Someone recreates the folder after the scan; git still calls it prunable.
        try write("new work\n", to: "\(gone)/notes.txt")
        let result = await engine().cleanItems([item(for: report, size: 0)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.contains { $0.contains("is back") }, "\(result.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(gone)/notes.txt"))
        XCTAssertTrue(try git(["worktree", "list", "--porcelain"], in: repo).contains("/wt/comes-back"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees"), ["comes-back"])
    }

    func testPruneRefusedWhenAnotherMissingWorktreeLiesOnAnUnmountedVolume() async throws {
        let gone = try addWorktree("wt/plain-gone", branch: "plain-gone")
        let away = try addWorktree("wt/on-usb", branch: "on-usb")
        try FileManager.default.removeItem(atPath: gone)
        try FileManager.default.removeItem(atPath: away)
        // Re-point the second worktree's admin record at an unmounted volume.
        let volume = "/Volumes/PureMac-not-mounted-\(UUID().uuidString)"
        try write("\(volume)/wt/on-usb/.git\n", to: "\(repo!)/.git/worktrees/on-usb/gitdir")

        let listing = try git(["worktree", "list", "--porcelain"], in: repo)
        XCTAssertTrue(listing.contains("\(volume)/wt/on-usb"), listing)
        let error = await scanner().prune(path: gone, repository: repo)

        XCTAssertTrue(error?.contains("not mounted") == true, "\(error ?? "")")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees")), ["plain-gone", "on-usb"])
    }

    func testPruneIsOnlyForTheRowScannedAsPrunable() async throws {
        // A normal row whose folder vanished after the scan is not pruned silently.
        let vanishing = try makeMerged("vanishing")
        let report = try await inspect(vanishing)
        XCTAssertEqual(report.verdict.status, .safeToDelete)
        try FileManager.default.removeItem(atPath: vanishing)

        let result = await engine().cleanItems([item(for: report)]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.contains { $0.contains("rescan") }, "\(result.errors)")
        XCTAssertTrue(try git(["worktree", "list", "--porcelain"], in: repo).contains("/wt/vanishing"))
    }

    func testOrphanFolderGitDoesNotKnowStaysDisplayOnly() async throws {
        let ghost = "\(repo!)/.claude/worktrees/ghost"
        try write("gitdir: /nonexistent/worktrees/ghost\n", to: "\(ghost)/.git")
        try write("keep me\n", to: "\(ghost)/work.txt")
        let reports = await scanner().scan()
        let ghostReport = try XCTUnwrap(reports.first { GitWorktreeScanner.canonical($0.path) == GitWorktreeScanner.canonical(ghost) })
        XCTAssertEqual(ghostReport.verdict, .init(status: .orphan, reasons: [.notListedByGit]))
        let row = item(for: ghostReport)
        XCTAssertTrue(row.isSelectionBlocked)

        let result = await engine().cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(ghost)/work.txt"))
    }

    // MARK: Build artifacts inside worktrees

    /// Merged-looking worktree that has an untracked file, so it is Needs review.
    private func makeNeedsReview(_ name: String) throws -> String {
        let path = try addWorktree("wt/\(name)", branch: name)
        try commit(in: path, file: "\(name).txt")
        try mergeIntoMain(name)
        try write("notes\n", to: "\(path)/notes.md")
        return path
    }

    private func artifactItem(_ worktree: String, folders: [String], verdict: GitWorktreeSupport.Verdict? = nil) -> CleanableItem {
        let report = WorktreeArtifactsReport(
            worktreePath: worktree,
            repositoryPath: repo,
            branch: "x",
            head: nil,
            worktreeVerdict: verdict ?? .init(status: .needsReview, reasons: [.untrackedFiles(1)]),
            folders: folders.map { WorktreeArtifactFolder(relativePath: $0, bytes: 1_000) }
        )
        var item = CleanableItem(
            name: "Artifacts in \(report.displayName)",
            path: WorktreeArtifactSupport.rowPath(forWorktree: worktree),
            size: report.totalBytes,
            category: .gitWorktrees,
            isSelected: false,
            lastModified: nil
        )
        item.worktreeArtifacts = report
        return item
    }

    /// `git status` without refreshing the index, which would bump the
    /// worktree's activity time.
    private func status(_ path: String) throws -> String {
        try git(["--no-optional-locks", "status", "--porcelain"], in: path)
    }

    func testIgnoredBuildFoldersAreRemovedAndTheWorktreeStaysIntact() async throws {
        let review = try makeNeedsReview("artifacts-review")
        try write(String(repeating: "n", count: 200_000), to: "\(review)/node_modules/pkg/index.js")
        try write(String(repeating: "n", count: 120_000), to: "\(review)/apps/web/node_modules/dep/index.js")
        let protected = try addWorktree("wt/artifacts-protected", branch: "artifacts-protected")
        try write("uncommitted edit\n", to: "\(protected)/README.md")
        try write(String(repeating: "n", count: 90_000), to: "\(protected)/node_modules/pkg/index.js")
        for path in [review, protected] { try age(path) }
        let reviewReadme = try Data(contentsOf: URL(fileURLWithPath: "\(review)/README.md"))
        let protectedStatusBefore = try status(protected)
        let reviewStatusBefore = try status(review)

        let reviewReport = try await inspect(review)
        let protectedReport = try await inspect(protected)
        XCTAssertEqual(reviewReport.verdict, .init(status: .needsReview, reasons: [.untrackedFiles(1)]))
        XCTAssertEqual(protectedReport.verdict.status, .protected)
        let reviewArtifacts = await scanner().artifactReport(for: reviewReport)
        let protectedArtifacts = await scanner().artifactReport(for: protectedReport)
        let a = try XCTUnwrap(reviewArtifacts)
        let b = try XCTUnwrap(protectedArtifacts)
        XCTAssertEqual(a.folders.map(\.relativePath), ["apps/web/node_modules", "node_modules"])
        XCTAssertGreaterThanOrEqual(a.totalBytes, 320_000)
        XCTAssertEqual(b.folders.map(\.relativePath), ["node_modules"])
        XCTAssertNil(a.blocker)
        XCTAssertNil(b.blocker)

        var rows: [CleanableItem] = []
        for report in [a, b] {
            var row = CleanableItem(name: report.displayName, path: WorktreeArtifactSupport.rowPath(forWorktree: report.worktreePath),
                                    size: report.totalBytes, category: .gitWorktrees, isSelected: false, lastModified: nil)
            row.worktreeArtifacts = report
            XCTAssertFalse(row.isSelectionBlocked)
            XCTAssertTrue(row.requiresExplicitSelection, "never swept up by a bulk selection")
            XCTAssertTrue(row.isActionItem, "the generic delete route never sees this path")
            rows.append(row)
        }
        let result = await engine().cleanItems(rows) { _ in }

        XCTAssertEqual(result.itemsCleaned, 2, "\(result.errors)")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertGreaterThanOrEqual(result.freedSpace, 410_000)
        XCTAssertEqual(result.cleanedPaths, Set(rows.map(\.path)))
        for path in [review, protected] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: "\(path)/node_modules"))
            XCTAssertTrue(try git(["worktree", "list", "--porcelain"], in: repo).contains(path), "the worktree itself stays")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(review)/apps/web/node_modules"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(review)/apps/web"), "only the artifact folder goes, not its parents")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(review)/README.md")), reviewReadme)
        XCTAssertEqual(try status(review), reviewStatusBefore, "tracked and untracked files are as they were")
        XCTAssertEqual(try status(protected), protectedStatusBefore, "the uncommitted edit survives")
        XCTAssertEqual(try String(contentsOfFile: "\(protected)/README.md", encoding: .utf8), "uncommitted edit\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(review)/notes.md"))
        XCTAssertTrue(try git(["branch", "--list", "artifacts-review"], in: repo).contains("artifacts-review"))
    }

    func testTrackedOrUnignoredBuildFoldersAreRefused() async throws {
        let path = try makeNeedsReview("tracked-build")
        // `build/` is ignored by the repository's exclude file but one file in it is tracked.
        try write("build/\n", to: "\(repo!)/.git/info/exclude")
        try write("artifact\n", to: "\(path)/build/out.txt")
        try git(["add", "-f", "build/out.txt"], in: path)
        try git(["commit", "-q", "-m", "track build output"], in: path)
        // `dist/` is not ignored at all.
        try write("bundle\n", to: "\(path)/dist/app.js")
        try age(path)

        let scanner = scanner()
        let tracked = await scanner.checkArtifactFolder(worktree: path, relative: "build")
        let unignored = await scanner.checkArtifactFolder(worktree: path, relative: "dist")
        // `git check-ignore` already reports a folder with tracked content as
        // not ignored; `ls-files` is the second line of defence behind it.
        XCTAssertEqual(tracked, .refused("is not ignored by git"))
        XCTAssertEqual(unignored, .refused("is not ignored by git"))
        let listed = try git(["ls-files", "--", "build"], in: path)
        XCTAssertEqual(listed, "build/out.txt\n", "the file really is tracked")
        let report = try await inspect(path)
        let artifacts = await scanner.artifactReport(for: report)
        XCTAssertNil(artifacts, "neither folder is offered")

        // Even a stale row that lists them cannot delete them.
        let result = await engine().cleanItems([artifactItem(path, folders: ["build", "dist"])]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.joined().contains("build: is not ignored by git"), "\(result.errors)")
        XCTAssertTrue(result.errors.joined().contains("dist: is not ignored by git"), "\(result.errors)")
        XCTAssertEqual(try String(contentsOfFile: "\(path)/build/out.txt", encoding: .utf8), "artifact\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/dist/app.js"))
    }

    func testArtifactFoldersInCloudProviderStorageAreLeftAlone() async throws {
        // A `com~apple~` component marks iCloud state wherever it appears.
        let path = try addWorktree("com~apple~CloudDocs/artifacts", branch: "cloud-artifacts")
        try commit(in: path, file: "c.txt")
        try mergeIntoMain("cloud-artifacts")
        try write("notes\n", to: "\(path)/notes.md")
        try write("x\n", to: "\(path)/node_modules/pkg/index.js")
        try age(path)
        let report = try await inspect(path)
        let artifacts = await scanner().artifactReport(for: report)
        let row = artifactItem(path, folders: try XCTUnwrap(artifacts).folders.map(\.relativePath))

        let result = await engine().cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.joined().contains("node_modules: in iCloud Drive"), "\(result.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/node_modules/pkg/index.js"))
    }

    func testFolderBecomingTrackedAfterTheScanIsLeftAlone() async throws {
        let path = try makeNeedsReview("tracked-later")
        try write("x\n", to: "\(path)/node_modules/pkg/index.js")
        try age(path)
        let report = try await inspect(path)
        let artifacts = await scanner().artifactReport(for: report)
        let row = artifactItem(path, folders: try XCTUnwrap(artifacts).folders.map(\.relativePath))

        // After the scan someone force-adds a file inside the folder.
        try git(["add", "-f", "node_modules/pkg/index.js"], in: path)
        let result = await engine().cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(result.errors.joined().contains("node_modules: is not ignored by git"), "\(result.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/node_modules/pkg/index.js"))
    }

    func testSymlinkedAndEscapingArtifactFoldersAreRefused() async throws {
        let outside = root.appendingPathComponent("outside-artifacts").path
        try write("outside file\n", to: "\(outside)/node_modules/keep.txt")
        try write("other file\n", to: "\(outside)/apps-target/web/node_modules/keep.txt")
        let path = try makeNeedsReview("escaping")
        // `node_modules` is itself a symlink to a folder elsewhere.
        try FileManager.default.createSymbolicLink(atPath: "\(path)/node_modules", withDestinationPath: "\(outside)/node_modules")
        // `apps` is a symlink, so "apps/web/node_modules" resolves outside the worktree.
        try FileManager.default.createSymbolicLink(atPath: "\(path)/apps", withDestinationPath: "\(outside)/apps-target")
        // `.venv` is a symlink to a folder inside the worktree: still not a real folder.
        try write("v\n", to: "\(path)/real-venv/keep.txt")
        try FileManager.default.createSymbolicLink(atPath: "\(path)/.venv", withDestinationPath: "\(path)/real-venv")
        try age(path)

        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: "node_modules"), .refused("is a symlink"))
        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: "apps/web/node_modules"), .refused("resolves outside the worktree"))
        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: ".venv"), .refused("is a symlink"))
        XCTAssertEqual(WorktreeArtifactSupport.candidates(in: path), [], "symlinks are never walked or listed")

        let result = await engine().cleanItems([artifactItem(path, folders: ["node_modules", "apps/web/node_modules", ".venv"])]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.errors.joined().contains("is a symlink"), "\(result.errors)")
        XCTAssertTrue(result.errors.joined().contains("resolves outside the worktree"), "\(result.errors)")
        XCTAssertEqual(try String(contentsOfFile: "\(outside)/node_modules/keep.txt", encoding: .utf8), "outside file\n")
        XCTAssertEqual(try String(contentsOfFile: "\(outside)/apps-target/web/node_modules/keep.txt", encoding: .utf8), "other file\n")
        XCTAssertEqual(try String(contentsOfFile: "\(path)/real-venv/keep.txt", encoding: .utf8), "v\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: "\(path)/node_modules"), "\(outside)/node_modules")
    }

    func testPathsThatAreNotPlainBuildFoldersAreRefused() {
        let tmp = root.path
        for bad in ["", "/etc", "../outside", "a/../node_modules", "node_modules/../src", ".git", "src", "a/b/c/d/node_modules",
                    "node_modules//x", "./node_modules", ".git/node_modules"] {
            guard case .refused = WorktreeArtifactSupport.check(worktree: tmp, relative: bad) else {
                XCTFail("\(bad) should be refused")
                continue
            }
        }
    }

    func testCandidateWalkIsBoundedAndDoesNotCrossRepositories() throws {
        let tree = root.appendingPathComponent("walk").path
        try write("x", to: "\(tree)/node_modules/inner/node_modules/deep.js")
        try write("x", to: "\(tree)/a/b/c/node_modules/x.js")
        try write("x", to: "\(tree)/a/b/c/d/node_modules/x.js")
        try write("x", to: "\(tree)/packages/app/.next/x.js")
        try write("x", to: "\(tree)/.git/node_modules/x.js")
        try write("gitdir: /elsewhere\n", to: "\(tree)/nested/.git")
        try write("x", to: "\(tree)/nested/node_modules/x.js")
        try write("x", to: "\(tree)/plain-file/target")
        try FileManager.default.createDirectory(atPath: "\(tree)/real-target", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(tree)/linked", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(tree)/linked/dist", withDestinationPath: "\(tree)/real-target")

        XCTAssertEqual(WorktreeArtifactSupport.candidates(in: tree), ["a/b/c/node_modules", "node_modules", "packages/app/.next"])
    }

    func testBusyWorktreesBlockArtifactRows() async throws {
        // In use (injected process list), recent agent activity and a lock.
        let inUse = try makeNeedsReview("busy-in-use")
        try write("x\n", to: "\(inUse)/node_modules/a.js")
        let agent = try addWorktree(".claude/worktrees/busy-agent", branch: "busy-agent")
        try write("x\n", to: "\(agent)/node_modules/a.js")
        let locked = try addWorktree("wt/busy-locked", branch: "busy-locked")
        try write("x\n", to: "\(locked)/node_modules/a.js")
        try write("edit\n", to: "\(locked)/README.md")
        try git(["worktree", "lock", "--reason", "agent", locked], in: repo)
        let free = try makeNeedsReview("not-busy")
        try write("x\n", to: "\(free)/node_modules/a.js")
        for path in [inUse, locked, free] { try age(path) }

        let busyScanner = scanner(inUse: ["\(inUse)/Sources"])
        var blockers: [String: GitWorktreeSupport.Reason?] = [:]
        for path in [inUse, agent, locked, free] {
            let report = try await inspect(path, with: busyScanner)
            let artifacts = await busyScanner.artifactReport(for: report)
            blockers[path] = try XCTUnwrap(artifacts, path).blocker
            let row = artifactItem(path, folders: ["node_modules"], verdict: report.verdict)
            XCTAssertEqual(row.isSelectionBlocked, artifacts?.blocker != nil)
            XCTAssertFalse(row.isSelected)
        }

        XCTAssertEqual(blockers[inUse] ?? nil, .inUse)
        XCTAssertEqual(blockers[agent] ?? nil, .recentAgentActivity)
        XCTAssertEqual(blockers[locked] ?? nil, .locked)
        XCTAssertNil(blockers[free] ?? nil)
    }

    func testEngineRefusesWorktreesThatBecameBusyAfterTheScan() async throws {
        let locked = try makeNeedsReview("locked-later")
        try write("x\n", to: "\(locked)/node_modules/a.js")
        try age(locked)
        let row = artifactItem(locked, folders: ["node_modules"])
        try git(["worktree", "lock", "--reason", "agent started", locked], in: repo)

        let lockedResult = await engine().cleanItems([row]) { _ in }
        XCTAssertEqual(lockedResult.itemsCleaned, 0)
        XCTAssertEqual(lockedResult.errors.count, 1)
        XCTAssertTrue(lockedResult.errors.first?.hasPrefix(row.name) == true, "\(lockedResult.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(locked)/node_modules/a.js"))
        try git(["worktree", "unlock", locked], in: repo)

        // A real process working inside the worktree (a dev server, say).
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: locked)
        try sleeper.run()
        let busyResult = await engine().cleanItems([row]) { _ in }
        sleeper.terminate()
        for _ in 0..<100 where sleeper.isRunning { try await Task.sleep(nanoseconds: 30_000_000) }

        XCTAssertEqual(busyResult.itemsCleaned, 0)
        XCTAssertEqual(busyResult.errors.count, 1)
        XCTAssertTrue(busyResult.errors.first?.hasPrefix(row.name) == true, "\(busyResult.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(locked)/node_modules/a.js"))
    }

    func testArtifactRowsFollowTheirWorktreeAndAreAnOrphanOnlyWhenGone() async throws {
        // The worktree vanished (removed in the same batch): its folders went with it.
        let gone = try makeNeedsReview("gone-first")
        try write("x\n", to: "\(gone)/node_modules/a.js")
        let row = artifactItem(gone, folders: ["node_modules"])
        try git(["worktree", "remove", "--force", gone], in: repo)
        let after = await engine().cleanItems([row]) { _ in }
        XCTAssertEqual(after.itemsCleaned, 1, "\(after.errors)")
        XCTAssertEqual(after.freedSpace, 0)

        // A folder git does not list as a worktree is never touched.
        let ghost = "\(repo!)/.claude/worktrees/ghost-artifacts"
        try write("gitdir: /nonexistent/worktrees/ghost\n", to: "\(ghost)/.git")
        try write("x\n", to: "\(ghost)/node_modules/a.js")
        let ghostResult = await engine().cleanItems([artifactItem(ghost, folders: ["node_modules"])]) { _ in }
        XCTAssertEqual(ghostResult.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(ghost)/node_modules/a.js"))
    }

    func testNestedRepositoriesInsideAWorktreeAreNotWalkedOrDeleted() async throws {
        let path = try makeNeedsReview("nested-repo")
        // An agent worktree nested inside this worktree (its own .git file).
        try write("gitdir: /elsewhere/.git/worktrees/inner\n", to: "\(path)/.claude/worktrees/inner/.git")
        try write("x\n", to: "\(path)/.claude/worktrees/inner/node_modules/a.js")
        // An ignored folder that is itself a repository.
        try write("gitdir: /elsewhere\n", to: "\(path)/dist/.git")
        try write("x\n", to: "\(path)/dist/a.js")
        try age(path)

        XCTAssertEqual(WorktreeArtifactSupport.candidates(in: path), ["dist"], "the nested worktree is not entered")
        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: "dist"),
                       .nestedRepository(resolved: GitWorktreeScanner.canonical(path) + "/dist", at: "dist/.git"))
        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: ".claude/worktrees/inner/node_modules"),
                       .refused("is inside a nested repository"))
    }

    // MARK: Safety review 6: a repository deep inside a build folder

    func testRepositoryDeepInsideABuildFolderBlocksTheRowAndIsNeverDeleted() async throws {
        try exclude([".venv/"])
        let path = try makeNeedsReview("deep-repo")
        // `pip install -e git+https://…` clones into .venv/src/<pkg>.
        try write("[core]\n", to: "\(path)/.venv/src/pkg/.git/config")
        try write("def work(): pass\n", to: "\(path)/.venv/src/pkg/code.py")
        try write("x\n", to: "\(path)/.venv/lib/site.py")
        try write(String(repeating: "n", count: 50_000), to: "\(path)/node_modules/pkg/index.js")
        // A deeper one, and a .git that is a file (a worktree or submodule pointer).
        try write("gitdir: /elsewhere/.git/modules/m\n", to: "\(path)/node_modules/mod/vendor/.git")
        try age(path)
        let resolved = GitWorktreeScanner.canonical(path)

        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: ".venv"),
                       .nestedRepository(resolved: resolved + "/.venv", at: ".venv/src/pkg/.git"))
        XCTAssertEqual(WorktreeArtifactSupport.check(worktree: path, relative: "node_modules"),
                       .nestedRepository(resolved: resolved + "/node_modules", at: "node_modules/mod/vendor/.git"))

        // At scan: the folders are listed, the row is blocked and cannot be selected.
        let report = try await inspect(path)
        XCTAssertEqual(report.verdict, .init(status: .protected, reasons: [.nestedRepositoryInIgnored]))
        let scanned = await scanner().artifactReport(for: report)
        let artifacts = try XCTUnwrap(scanned)
        XCTAssertEqual(artifacts.folders.map(\.relativePath), [".venv", "node_modules"])
        XCTAssertNotNil(artifacts.nestedRepository)
        XCTAssertEqual(artifacts.blocker, .nestedRepositoryInIgnored)
        var row = artifactItem(path, folders: [])
        row.worktreeArtifacts = artifacts
        XCTAssertTrue(row.isSelectionBlocked)

        // At clean: a stale row from before the repository existed still deletes neither folder.
        let result = await engine().cleanItems([artifactItem(path, folders: [".venv", "node_modules"])]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertTrue(result.errors.joined().contains(".venv: contains a repository (.venv/src/pkg/.git)"), "\(result.errors)")
        XCTAssertTrue(result.errors.joined().contains("node_modules: contains a repository"), "\(result.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/.venv/src/pkg/code.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/.venv/src/pkg/.git/config"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/node_modules/mod/vendor/.git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/node_modules/pkg/index.js"))
    }

    func testBuildFolderWithoutRepositoriesIsStillRemoved() async throws {
        let path = try makeNeedsReview("no-deep-repo")
        try write(String(repeating: "n", count: 50_000), to: "\(path)/node_modules/pkg/.gitignore")
        try write("x\n", to: "\(path)/node_modules/pkg/.github/workflows/ci.yml")
        try age(path)
        let report = try await inspect(path)
        XCTAssertEqual(report.verdict, .init(status: .needsReview, reasons: [.untrackedFiles(1)]), "names like .gitignore and .github are not repositories")
        let scanned = await scanner().artifactReport(for: report)
        let artifacts = try XCTUnwrap(scanned)
        XCTAssertNil(artifacts.nestedRepository)
        XCTAssertNil(artifacts.blocker)

        let result = await engine().cleanItems([artifactItem(path, folders: ["node_modules"])]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(path)/node_modules"))
    }

    // MARK: Safety review 1: the Overview never removes worktrees

    @MainActor
    func testOverviewNeverSelectsCountsOrRemovesScannedWorktrees() async throws {
        let safe = try makeMerged("overview-safe")
        let review = try addWorktree("wt/overview-review", branch: "overview-review")
        try commit(in: review, file: "r.txt")
        try git(["push", "-q", "origin", "overview-review"], in: review)
        try age(review)
        let gone = try addWorktree("wt/overview-gone", branch: "overview-gone")
        try FileManager.default.removeItem(atPath: gone)

        var rows: [CleanableItem] = []
        for path in [safe, review, gone] {
            var row = item(for: try await inspect(path))
            row.isSelected = true // what a default-selected row would look like
            rows.append(row)
        }
        XCTAssertEqual(rows.map { $0.gitWorktree?.verdict.status }, [.safeToDelete, .needsReview, .orphan])

        let state = AppState(performStartupTasks: false)
        state.categoryResults[.gitWorktrees] = CategoryResult(category: .gitWorktrees, items: rows, totalSize: 3_000)
        state.scanState = .completed
        let before = try git(["worktree", "list", "--porcelain"], in: repo)

        XCTAssertTrue(state.isReviewedInCategoryOnly(.gitWorktrees))
        XCTAssertTrue(rows.allSatisfy { state.isItemSelected($0) }, "selected on the category screen")
        XCTAssertEqual(state.totalSelectedSize, 0, "the Overview total ignores worktrees")
        XCTAssertTrue(state.overviewSelectedItems.isEmpty, "so does its confirmation list")

        // The Overview category checkbox neither reads nor writes worktree selection.
        let binding = state.categoryBinding(for: .gitWorktrees)
        XCTAssertFalse(binding.wrappedValue)
        state.deselectAllInCategory(.gitWorktrees)
        binding.wrappedValue = true
        XCTAssertTrue(rows.allSatisfy { !state.isItemSelected($0) }, "the checkbox must not select worktrees")

        // Clean All, manual and scheduled, with every row selected.
        for row in rows { state.toggleItem(row) }
        state.cleanAll()
        state.cleanAll(scheduled: true)
        state.cleanAll(itemIDs: Set(rows.map(\.id)))
        XCTAssertEqual(state.scanState, .completed, "cleanAll must not start a clean for worktree rows")
        try await Task.sleep(nanoseconds: 300_000_000)

        for path in [safe, review] { XCTAssertTrue(FileManager.default.fileExists(atPath: path), path) }
        XCTAssertEqual(try git(["worktree", "list", "--porcelain"], in: repo), before, "no worktree remove and no prune ran")
        XCTAssertTrue(try git(["branch", "--list", "overview-safe"], in: repo).contains("overview-safe"), "no branch -d ran")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees")),
                       ["overview-safe", "overview-review", "overview-gone"])
    }

    // MARK: Safety review 2: no prune after a moved repository or worktree

    @discardableResult
    private func makeDetachedWorktreeWithWork(_ relative: String) throws -> String {
        let path = "\(repo!)/\(relative)"
        try git(["worktree", "add", "-q", "--detach", path, "main"], in: repo)
        try commit(in: path, file: "only-here.txt", "a commit no branch has")
        try write("staged\n", to: "\(path)/staged.txt")
        try git(["add", "staged.txt"], in: path)
        return path
    }

    func testPruneIsRefusedWhenTheRepositoryFolderWasMoved() async throws {
        let w1 = try makeDetachedWorktreeWithWork(".claude/worktrees/w1")
        let w2 = try addWorktree(".claude/worktrees/w2", branch: "w2")
        let commitInW1 = try git(["rev-parse", "HEAD"], in: w1).trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = GitWorktreeScanner.canonical(root.path) + "/moved"
        try FileManager.default.moveItem(atPath: repo, toPath: moved)

        // Both worktrees are listed as missing, and the plain guards pass.
        let listing = try git(["worktree", "list", "--porcelain"], in: moved)
        XCTAssertEqual(listing.components(separatedBy: "prunable").count - 1, 2, listing)
        var movedScanner = GitWorktreeScanner(homeDirectory: root.path, gitPath: gitPath)
        movedScanner.repositoryHints = [moved]
        movedScanner.workingDirectories = { [] }
        let reports = await movedScanner.scan()
        let prunable = reports.filter { $0.verdict.isPrunableOrphan }
        XCTAssertEqual(prunable.count, 2, "\(reports.map(\.verdict))")

        let error = await movedScanner.prune(path: w1, repository: moved)

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("worktree repair") == true, "\(error ?? "")")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: "\(moved)/.git/worktrees")), ["w1", "w2"])

        // Through the engine, with the rows as scanned.
        let rows = prunable.map { item(for: $0, size: 0) }
        let result = await engine().cleanItems(rows) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.errors.count, 2, "\(result.errors)")
        XCTAssertTrue(result.errors.allSatisfy { $0.contains("worktree repair") }, "\(result.errors)")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: "\(moved)/.git/worktrees")), ["w1", "w2"])

        // The advice works: after the repair both worktrees are intact.
        let newW1 = moved + "/.claude/worktrees/w1"
        let newW2 = moved + "/.claude/worktrees/w2"
        try git(["worktree", "repair", newW1, newW2], in: moved)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: newW1).trimmingCharacters(in: .whitespacesAndNewlines), commitInW1)
        XCTAssertTrue(try git(["status", "--porcelain"], in: newW1).contains("A  staged.txt"))
        XCTAssertFalse(try git(["worktree", "list", "--porcelain"], in: moved).contains("prunable"))
        _ = w2
    }

    func testPruneIsRefusedWhenAWorktreeFolderWasRenamed() async throws {
        let renamed = try makeDetachedWorktreeWithWork("wt/before")
        let gone = try addWorktree("wt/really-gone", branch: "really-gone")
        let after = "\(repo!)/wt/after"
        try FileManager.default.moveItem(atPath: renamed, toPath: after)
        try FileManager.default.removeItem(atPath: gone)

        // Both look missing to git; only one was deleted.
        let error = await scanner().prune(path: gone, repository: repo)

        XCTAssertTrue(error?.contains("worktree repair") == true, "\(error ?? "")")
        XCTAssertTrue(error?.contains(after) == true, "names the folder that must be repaired: \(error ?? "")")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees")), ["before", "really-gone"])

        // Once it is repaired, the deleted one can be pruned and the renamed one survives.
        try git(["worktree", "repair", after], in: repo)
        let retry = await scanner().prune(path: gone, repository: repo)
        XCTAssertNil(retry)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "\(repo!)/.git/worktrees"), ["before"])
        XCTAssertTrue(try git(["status", "--porcelain"], in: after).contains("A  staged.txt"))
    }

    // MARK: Safety review 3: ignored work is not Safe to delete

    private func exclude(_ lines: [String]) throws {
        let file = "\(repo!)/.git/info/exclude"
        let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        try write(existing + lines.joined(separator: "\n") + "\n", to: file)
    }

    func testIgnoredFilesAndNestedRepositoriesAreNotSafeToDelete() async throws {
        try exclude(["vendor/", "config/master.key", "secrets/"])
        // Same fixture as the review: an ignored nested repository with a commit
        // nothing else has, an ignored key and an ignored .env in an ignored folder.
        let nested = try makeMerged("ignored-nested")
        try git(["init", "-q", "\(nested)/vendor/lib"], in: nested)
        try commit(in: "\(nested)/vendor/lib", file: "unique.txt", "work that exists only in vendor/lib")
        try write("key\n", to: "\(nested)/config/master.key")
        try write("TOKEN=1\n", to: "\(nested)/secrets/.env")
        let status = try git(["status", "--porcelain=v2", "--ignored=matching", "--untracked-files=normal"], in: nested)
        XCTAssertEqual(Set(status.split(separator: "\n").map(String.init)), ["! config/master.key", "! secrets/", "! vendor/"], status)
        try age(nested)

        let keysOnly = try makeMerged("ignored-keys")
        try write("key\n", to: "\(keysOnly)/config/master.key")
        try write("TOKEN=1\n", to: "\(keysOnly)/secrets/.env")
        try age(keysOnly)

        let plainIgnored = try makeMerged("ignored-plain")
        try write("log\n", to: "\(plainIgnored)/config/master.key")
        try age(plainIgnored)

        let buildOnly = try makeMerged("ignored-build-only")
        try write("x\n", to: "\(buildOnly)/node_modules/pkg/index.js")
        try age(buildOnly)

        let depInNodeModules = try makeMerged("ignored-dep-repo")
        try git(["init", "-q", "\(depInNodeModules)/node_modules/dep"], in: depInNodeModules)
        try age(depInNodeModules)

        let nestedReport = try await inspect(nested)
        XCTAssertEqual(nestedReport.verdict, .init(status: .protected, reasons: [.nestedRepositoryInIgnored]))
        let keysReport = try await inspect(keysOnly)
        XCTAssertEqual(keysReport.verdict, .init(status: .needsReview, reasons: [.envFiles, .ignoredOutsideBuildFolders(2)]),
                       "`secrets/.env` is found inside the ignored folder")
        let plainReport = try await inspect(plainIgnored)
        XCTAssertEqual(plainReport.verdict, .init(status: .needsReview, reasons: [.ignoredOutsideBuildFolders(1)]))
        let buildReport = try await inspect(buildOnly)
        XCTAssertEqual(buildReport.verdict.status, .safeToDelete, "build folders alone stay Safe to delete")
        let depReport = try await inspect(depInNodeModules)
        XCTAssertEqual(depReport.verdict, .init(status: .protected, reasons: [.nestedRepositoryInIgnored]),
                       "a .git inside a build folder counts too")

        // The engine refuses the Protected rows and leaves every byte in place.
        let rows = [item(for: nestedReport), item(for: depReport)]
        XCTAssertTrue(rows.allSatisfy(\.isSelectionBlocked))
        let result = await engine().cleanItems(rows) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(nested)/vendor/lib/unique.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(nested)/config/master.key"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(depInNodeModules)/node_modules/dep/.git"))
    }

    func testMacOSLitterAndIgnoredSymlinksKeepAWorktreeSafe() async throws {
        try exclude([".DS_Store", "._*", "Icon?", ".localized", "scratch/", "cache-link", "notes.txt"])
        let outside = root.appendingPathComponent("link-target").path
        try write("precious\n", to: "\(outside)/precious.txt")
        // A repository behind a symlink must never be walked into.
        try FileManager.default.createDirectory(atPath: "\(outside)/inner-repo/.git", withIntermediateDirectories: true)

        let safe = try makeMerged("litter-only")
        try write("", to: "\(safe)/.DS_Store")
        try write("", to: "\(safe)/._x")
        try write("", to: "\(safe)/Icon\r")
        try write("", to: "\(safe)/.localized")
        try write("", to: "\(safe)/README-sub/.DS_Store")
        try write("", to: "\(safe)/scratch/.DS_Store")
        try write("", to: "\(safe)/scratch/deeper/._y")
        try FileManager.default.createSymbolicLink(atPath: "\(safe)/link-out", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: "\(safe)/cache-link", withDestinationPath: outside + "/inner-repo")
        let listing = try git(["status", "--porcelain=v2", "--ignored=matching", "--untracked-files=normal"], in: safe)
        for expected in ["! .DS_Store", "! ._x", "! .localized", "! link-out", "! cache-link", "! scratch/"] {
            XCTAssertTrue(listing.contains(expected), "\(expected) in \(listing)")
        }
        try age(safe)
        for link in ["link-out", "cache-link"] {
            let touch = Process()
            touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            touch.arguments = ["-h", "-t", "202601011200", "\(safe)/\(link)"]
            try touch.run()
            touch.waitUntilExit()
        }

        let withNotes = try makeMerged("litter-and-notes")
        try write("", to: "\(withNotes)/.DS_Store")
        try write("mine\n", to: "\(withNotes)/notes.txt")
        try age(withNotes)

        let folderWithWork = try makeMerged("litter-and-work")
        try write("", to: "\(folderWithWork)/scratch/.DS_Store")
        try write("mine\n", to: "\(folderWithWork)/scratch/deeper/notes.txt")
        try age(folderWithWork)

        let safeReport = try await inspect(safe)
        XCTAssertEqual(safeReport.verdict.status, .safeToDelete, "\(safeReport.verdict)")
        let notesReport = try await inspect(withNotes)
        XCTAssertEqual(notesReport.verdict, .init(status: .needsReview, reasons: [.ignoredOutsideBuildFolders(1)]))
        let workReport = try await inspect(folderWithWork)
        XCTAssertEqual(workReport.verdict, .init(status: .needsReview, reasons: [.ignoredOutsideBuildFolders(1)]),
                       "scratch/ holds a file that is not litter")

        // Removing the worktree removes the links, never what they point to.
        let result = await engine().cleanItems([item(for: safeReport)]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1, "\(result.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: safe))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outside)/precious.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(outside)/inner-repo/.git"))
    }

    func testIgnoredFolderWalkIsBoundedAndNeverFollowsSymlinks() throws {
        let worktree = root.appendingPathComponent("walk").path
        let outside = root.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: "\(outside)/repo/.git", withIntermediateDirectories: true)
        try write("x\n", to: "\(worktree)/cache/a.txt")
        try FileManager.default.createSymbolicLink(atPath: "\(worktree)/cache/link", withDestinationPath: "\(outside)/repo")
        try FileManager.default.createSymbolicLink(atPath: "\(worktree)/cache/.env.link", withDestinationPath: outside)

        let followed = GitWorktreeScanner.inspectIgnoredFolders(worktree: worktree, ignored: ["cache/"])
        XCTAssertNil(followed.nestedRepository, "a symlink to a repository is not walked")
        XCTAssertFalse(followed.incomplete)
        XCTAssertEqual(followed.envFiles, ["cache/.env.link"], "the link itself is listed, its target is not entered")

        for index in 0..<30 { try write("x\n", to: "\(worktree)/big/f\(index).txt") }
        let bounded = GitWorktreeScanner.inspectIgnoredFolders(worktree: worktree, ignored: ["big/"], entryLimit: 10)
        XCTAssertTrue(bounded.incomplete)
        let unreadable = GitWorktreeScanner.inspectIgnoredFolders(worktree: worktree, ignored: ["missing/"])
        XCTAssertTrue(unreadable.incomplete, "a folder that cannot be read has not been checked")

        // .env* inside build folders is noise and is not collected; .git is always found.
        try write("x\n", to: "\(worktree)/node_modules/pkg/.env.example")
        try write("x\n", to: "\(worktree)/node_modules/pkg/.git")
        let build = GitWorktreeScanner.inspectIgnoredFolders(worktree: worktree, ignored: ["node_modules/"])
        XCTAssertEqual(build.nestedRepository, "node_modules/pkg/.git")
        XCTAssertEqual(build.envFiles, [])
    }

    // MARK: Safety review 4: the re-check refuses a worse verdict

    func testEngineRefusesAWorktreeThatGotWorseSinceTheScan() async throws {
        let worktree = try makeMerged("gets-worse")
        let report = try await inspect(worktree)
        XCTAssertEqual(report.verdict.status, .safeToDelete)
        let row = item(for: report)

        // After the scan: a .env appears. Needs review is not "blocked", but it is worse.
        try write("SECRET=1\n", to: "\(worktree)/.env")
        let now = try await inspect(worktree)
        XCTAssertEqual(now.verdict.status, .needsReview)
        XCTAssertFalse(now.verdict.blocksSelection)

        let result = await engine().cleanItems([row]) { _ in }

        XCTAssertEqual(result.itemsCleaned, 0)
        let message = try XCTUnwrap(result.errors.first)
        XCTAssertTrue(message.contains("changed since the scan"), message)
        XCTAssertTrue(message.contains(GitWorktreeSupport.Reason.envFiles.localizedDescription), "lists the new reason: \(message)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(worktree)/.env"))

        // A row the user already saw as Needs review with these reasons still goes through.
        let seen = item(for: now)
        let accepted = await engine().cleanItems([seen]) { _ in }
        XCTAssertEqual(accepted.itemsCleaned, 1, "\(accepted.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    // MARK: Safety review 5: the base branch is a branch, resolved in the repository

    func testBaseBranchSettingResolvesToFullBranchRefsOnly() async throws {
        try git(["checkout", "-q", "-b", "parking"], in: repo)
        var resolver = scanner()

        let automatic = await resolver.resolveBaseRef(in: repo)
        XCTAssertEqual(automatic, "refs/remotes/origin/main", "automatic order")
        resolver.baseBranchOverride = "main"
        let local = await resolver.resolveBaseRef(in: repo)
        XCTAssertEqual(local, "refs/heads/main")
        resolver.baseBranchOverride = "origin/main"
        let remote = await resolver.resolveBaseRef(in: repo)
        XCTAssertEqual(remote, "refs/remotes/origin/main")
        resolver.baseBranchOverride = "refs/remotes/origin/main"
        let full = await resolver.resolveBaseRef(in: repo)
        XCTAssertEqual(full, "refs/remotes/origin/main")
        let sha = try git(["rev-parse", "main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["tag", "v1"], in: repo)
        for refused in ["HEAD", "@", "FETCH_HEAD", sha, String(sha.prefix(8)), "v1", "refs/tags/v1", "refs/stash", "nope"] {
            resolver.baseBranchOverride = refused
            let resolved = await resolver.resolveBaseRef(in: repo)
            XCTAssertNil(resolved, refused)
        }
    }

    func testHeadAsBaseBranchNeverMakesUnmergedWorkLookMerged() async throws {
        // Pushed (so nothing is "unique"), never merged into main.
        let path = try addWorktree("wt/unmerged-pushed", branch: "unmerged-pushed")
        try commit(in: path, file: "u.txt")
        try git(["push", "-q", "origin", "unmerged-pushed"], in: path)
        try age(path)

        for name in ["HEAD", "@", "FETCH_HEAD"] {
            var withBase = scanner()
            withBase.baseBranchOverride = name
            let report = try await inspect(path, with: withBase)
            XCTAssertEqual(report.verdict, .init(status: .needsReview, reasons: [.noBaseBranch]), name)

            // Even with branch deletion on, the branch survives the removal.
            let settings = GitWorktreeSettings(baseBranch: name, deleteMergedBranch: true)
            let result = await engine(settings).cleanItems([item(for: report)]) { _ in }
            XCTAssertTrue(result.notes.isEmpty, "\(result.notes)")
            XCTAssertTrue(try git(["branch", "--list", "unmerged-pushed"], in: repo).contains("unmerged-pushed"), name)
            if result.itemsCleaned == 1 {
                // The folder is gone but the work is kept on its branch; recreate it for the next name.
                try git(["worktree", "add", "-q", path, "unmerged-pushed"], in: repo)
                try age(path)
            }
        }
    }
}

@MainActor
final class WorktreeScheduledCleanupTests: XCTestCase {
    func testWorktreesAreNeverPartOfSmartScanOrScheduledCleanup() {
        XCTAssertTrue(CleaningCategory.scannable.contains(.gitWorktrees))
        XCTAssertFalse(CleaningCategory.smartScannable.contains(.gitWorktrees))

        let state = AppState(performStartupTasks: false)
        var item = CleanableItem(name: "r · done", path: "/nonexistent/r/wt/done", size: 4_096, category: .gitWorktrees,
                                 isSelected: true, lastModified: nil)
        item.gitWorktree = GitWorktreeReport(path: item.path, repositoryPath: "/nonexistent/r", branch: "done", head: nil,
                                             verdict: .init(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)]), lastActivity: nil)
        state.categoryResults[.gitWorktrees] = CategoryResult(category: .gitWorktrees, items: [item], totalSize: item.size)
        state.scanState = .completed
        XCTAssertTrue(state.isItemSelected(item))

        state.cleanAll(scheduled: true)

        XCTAssertEqual(state.scanState, .completed, "a scheduled run must not start cleaning worktrees")
        XCTAssertEqual(state.categoryResults[.gitWorktrees]?.items.map(\.id), [item.id])
    }

    func testArtifactRowsAreNeverPreselectedBulkSelectedOrScheduled() {
        func artifactRow(_ verdict: GitWorktreeSupport.Verdict) -> CleanableItem {
            let report = WorktreeArtifactsReport(
                worktreePath: "/nonexistent/r/wt/x", repositoryPath: "/nonexistent/r", branch: "x", head: nil,
                worktreeVerdict: verdict, folders: [WorktreeArtifactFolder(relativePath: "node_modules", bytes: 8_192)]
            )
            var row = CleanableItem(name: "Artifacts in r · x", path: WorktreeArtifactSupport.rowPath(forWorktree: report.worktreePath),
                                    size: report.totalBytes, category: .gitWorktrees, isSelected: false, lastModified: nil)
            row.worktreeArtifacts = report
            return row
        }
        let open = artifactRow(.init(status: .needsReview, reasons: [.untrackedFiles(1)]))
        let busy = artifactRow(.init(status: .protected, reasons: [.trackedChanges(1), .inUse]))
        XCTAssertFalse(open.isSelected)
        XCTAssertFalse(open.isSelectionBlocked)
        XCTAssertTrue(open.requiresExplicitSelection)
        XCTAssertTrue(busy.isSelectionBlocked)
        XCTAssertEqual(open.sizeInCategoryTotal, 0, "the worktree row already counts these bytes")

        let state = AppState(performStartupTasks: false)
        state.categoryResults[.gitWorktrees] = CategoryResult(category: .gitWorktrees, items: [open, busy], totalSize: 8_192)
        state.scanState = .completed

        state.selectAllInCategory(.gitWorktrees)
        XCTAssertFalse(state.isItemSelected(open), "a category-wide selection skips artifact rows")
        state.toggleItem(busy)
        XCTAssertFalse(state.isItemSelected(busy), "a blocked row cannot be toggled on")
        state.toggleItem(open)
        XCTAssertTrue(state.isItemSelected(open), "a click on the row itself selects it")

        state.cleanAll(scheduled: true)
        XCTAssertEqual(state.scanState, .completed, "scheduled cleaning never touches worktree artifacts")
        XCTAssertEqual(state.categoryResults[.gitWorktrees]?.items.count, 2)
    }
}

final class WorktreeRemovalRiskTests: XCTestCase {
    func testWorktreesNeedThreeAcknowledgements() {
        XCTAssertTrue(RemovalRisk.requiresAcknowledgement(.gitWorktrees))
        XCTAssertEqual(RemovalRisk.risks(for: .gitWorktrees, items: [], worktreeSettings: GitWorktreeSettings()).count, 3)
    }

    func testBranchDeletionAndPruneChangeTheRisksShown() {
        func item(_ verdict: GitWorktreeSupport.Verdict) -> CleanableItem {
            var item = CleanableItem(name: "x", path: "/r/wt/x", size: 0, category: .gitWorktrees, isSelected: false, lastModified: nil)
            item.gitWorktree = GitWorktreeReport(path: item.path, repositoryPath: "/r", branch: "x", head: nil, verdict: verdict, lastActivity: nil)
            return item
        }
        let removable = item(.init(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)]))
        let prunable = item(.init(status: .orphan, reasons: [.prunable]))
        let off = GitWorktreeSettings()
        let on = GitWorktreeSettings(deleteMergedBranch: true)

        let keep = RemovalRisk.risks(for: .gitWorktrees, items: [removable], worktreeSettings: off)
        let drop = RemovalRisk.risks(for: .gitWorktrees, items: [removable], worktreeSettings: on)
        XCTAssertEqual(keep.count, 3)
        XCTAssertEqual(drop.count, 3)
        XCTAssertNotEqual(keep[1], drop[1], "the second risk changes with the branch setting")
        XCTAssertTrue(drop[1].contains("git branch -d"))

        let pruneOnly = RemovalRisk.risks(for: .gitWorktrees, items: [prunable], worktreeSettings: on)
        XCTAssertEqual(pruneOnly.count, 1)
        XCTAssertTrue(pruneOnly[0].contains("git worktree prune"))
        XCTAssertEqual(RemovalRisk.risks(for: .gitWorktrees, items: [removable, prunable], worktreeSettings: off).count, 4)

        let prompt = RemovalRisk.agentPrompt(category: .gitWorktrees, found: [removable, prunable], proposed: [], worktreeSettings: on)
        XCTAssertTrue(prompt.contains("`worktree prune r`") || prompt.contains("`worktree prune /r`"), prompt)
        XCTAssertTrue(prompt.contains("then `git branch -d` for safe rows"))
    }

    func testArtifactRowsHaveTheirOwnRisksAndPromptAction() {
        let report = WorktreeArtifactsReport(
            worktreePath: "/r/.claude/worktrees/wip", repositoryPath: "/r", branch: "wip", head: nil,
            worktreeVerdict: .init(status: .protected, reasons: [.trackedChanges(2)]),
            folders: [WorktreeArtifactFolder(relativePath: "node_modules", bytes: 4_096), WorktreeArtifactFolder(relativePath: "apps/web/.next", bytes: 4_096)]
        )
        var artifacts = CleanableItem(name: "Artifacts in r · wip", path: WorktreeArtifactSupport.rowPath(forWorktree: report.worktreePath),
                                      size: 8_192, category: .gitWorktrees, isSelected: false, lastModified: nil)
        artifacts.worktreeArtifacts = report
        var removable = CleanableItem(name: "done", path: "/r/wt/done", size: 1_024, category: .gitWorktrees, isSelected: true, lastModified: nil)
        removable.gitWorktree = GitWorktreeReport(path: removable.path, repositoryPath: "/r", branch: "done", head: nil,
                                                  verdict: .init(status: .safeToDelete, reasons: [.mergedAndIdle(days: 9)]), lastActivity: nil)
        let settings = GitWorktreeSettings()

        let onlyArtifacts = RemovalRisk.risks(for: .gitWorktrees, items: [artifacts], worktreeSettings: settings)
        XCTAssertEqual(onlyArtifacts.count, 2, "no worktree-removal risks when no worktree is removed")
        XCTAssertTrue(onlyArtifacts[0].contains("node_modules"))
        let both = RemovalRisk.risks(for: .gitWorktrees, items: [artifacts, removable], worktreeSettings: settings)
        XCTAssertEqual(both.count, 5)

        let prompt = RemovalRisk.agentPrompt(category: .gitWorktrees, found: [artifacts, removable], proposed: [artifacts.id], worktreeSettings: settings)
        let rows = prompt.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| #") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].contains("`delete ignored folders r:.claude/worktrees/wip/{node_modules,apps/web/.next}`"), "\(rows[0])")
        XCTAssertTrue(rows[0].contains("| ✔ |") && rows[0].contains("artifacts: wip") && rows[0].contains("PROTECTED; uncommitted changes (2)"), "\(rows[0])")
        XCTAssertTrue(prompt.contains("the worktree stays"))
    }

    func testAgentPromptListsEveryFoundItemAndMarksProposedOnes() {
        func item(_ name: String, _ status: GitWorktreeSupport.Status, _ reasons: [GitWorktreeSupport.Reason], repo: String? = "/r") -> CleanableItem {
            var item = CleanableItem(name: name, path: "/r/.claude/worktrees/\(name)", size: 2_048, category: .gitWorktrees, isSelected: status == .safeToDelete, lastModified: nil)
            item.gitWorktree = GitWorktreeReport(path: item.path, repositoryPath: repo, branch: name, head: nil, verdict: .init(status: status, reasons: reasons), lastActivity: nil)
            return item
        }
        let safe = item("done", .safeToDelete, [.mergedAndIdle(days: 9)])
        let kept = item("wip|x", .protected, [.trackedChanges(2)])
        let ghost = item("ghost", .orphan, [.notListedByGit], repo: nil)

        let prompt = RemovalRisk.agentPrompt(category: .gitWorktrees, found: [safe, kept, ghost], proposed: [safe.id])
        let rows = prompt.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| #") }

        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].contains("| ✔ |") && rows[0].contains("`worktree remove r:.claude/worktrees/done`") && rows[0].contains("safe; merged, idle 9d"))
        XCTAssertTrue(rows[1].contains("| · |") && rows[1].contains("wip\\|x") && rows[1].contains("PROTECTED; uncommitted changes (2)"))
        XCTAssertTrue(rows[2].contains("none (display only)"))
        XCTAssertTrue(prompt.contains("Repos: r = /r"))
        XCTAssertTrue(prompt.contains("Read-only: do not delete"))
        XCTAssertTrue(prompt.contains("No sub-agents"))
        XCTAssertTrue(prompt.contains("Proposed: 1 of 3 items"))
    }
}

@MainActor
final class SmartScanOptInTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "PureMac.SmartScanOptInTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWorktreesJoinOnlyAManualSmartScanAndOnlyWhenAdded() {
        XCTAssertEqual(CleaningCategory.smartScanOptional, [.gitWorktrees])
        XCTAssertEqual(CleaningCategory.smartScanCategories(defaults: defaults), CleaningCategory.smartScannable)
        XCTAssertFalse(CleaningCategory.smartScanCategories(defaults: defaults).contains(.gitWorktrees), "off by default")

        defaults.set(true, forKey: GitWorktreeSettings.includeInSmartScanKey)
        let added = CleaningCategory.smartScanCategories(defaults: defaults)
        XCTAssertEqual(added, CleaningCategory.scannable.filter { CleaningCategory.smartScannable.contains($0) || $0 == .gitWorktrees })
        XCTAssertFalse(CleaningCategory.smartScannable.contains(.gitWorktrees), "scheduled scans keep skipping worktrees")
    }

    func testAddingKeepsTheChoiceAndNeverSelectsWorktrees() {
        let state = AppState(performStartupTasks: false, settingsDefaults: defaults)
        XCTAssertFalse(state.isAddedToSmartScan(.gitWorktrees))

        state.setAddedToSmartScan(.gitWorktrees, true)
        XCTAssertTrue(state.isAddedToSmartScan(.gitWorktrees))
        XCTAssertTrue(defaults.bool(forKey: GitWorktreeSettings.includeInSmartScanKey))
        XCTAssertTrue(state.smartScanCategories.contains(.gitWorktrees))
        XCTAssertTrue(state.isReviewedInCategoryOnly(.gitWorktrees), "adding the scan does not open the Overview's Clean button")

        let item = CleanableItem(name: "r · x", path: "/r/wt/x", size: 4_096, category: .gitWorktrees, isSelected: true, lastModified: nil)
        state.categoryResults[.gitWorktrees] = CategoryResult(category: .gitWorktrees, items: [item], totalSize: 4_096)
        XCTAssertEqual(state.totalSelectedSize, 0)

        state.setAddedToSmartScan(.gitWorktrees, false)
        XCTAssertFalse(state.smartScanCategories.contains(.gitWorktrees))
    }

    func testAddingFromTheOverviewScansInItsRowUntilStopped() {
        let state = AppState(performStartupTasks: false, settingsDefaults: defaults)
        state.addToSmartScan(.gitWorktrees)
        XCTAssertTrue(state.isAddedToSmartScan(.gitWorktrees), "before any scan the choice is only saved")
        XCTAssertFalse(state.scanState.isActive)
        state.setAddedToSmartScan(.gitWorktrees, false)

        state.scanState = .completed
        state.addToSmartScan(.trashBins)
        XCTAssertFalse(state.scanState.isActive, "only optional categories are added")

        state.addToSmartScan(.gitWorktrees)
        XCTAssertTrue(state.scanState.isActive)
        XCTAssertTrue(state.isAddedToSmartScan(.gitWorktrees), "the choice is saved before the scan ends")
        XCTAssertTrue(state.canAddToSmartScan, "another optional category can join this scan")

        state.cancelScan()
        XCTAssertNil(state.categoryBeingAdded)
        XCTAssertTrue(state.queuedScanCategories.isEmpty)
        XCTAssertFalse(state.scanState.isActive)
        XCTAssertTrue(state.isAddedToSmartScan(.gitWorktrees), "stopping the scan keeps the choice")
    }

    func testAddingDuringASmartScanJoinsItsQueueOnce() {
        let state = AppState(performStartupTasks: false, settingsDefaults: defaults)
        state.startSmartScan()
        XCTAssertTrue(state.canAddToSmartScan)
        let queued = state.queuedScanCategories.count

        state.addToSmartScan(.gitWorktrees)
        state.addToSmartScan(.gitWorktrees)
        XCTAssertEqual(state.queuedScanCategories.count, queued + 1)
        XCTAssertEqual(state.queuedScanCategories.last, .gitWorktrees)
        XCTAssertTrue(state.isAddedToSmartScan(.gitWorktrees))
        state.cancelScan()

        state.scanSingleCategory(.trashBins)
        XCTAssertFalse(state.canAddToSmartScan, "a category screen's own scan takes no additions")
        state.addToSmartScan(.gitWorktrees)
        XCTAssertFalse(state.queuedScanCategories.contains(.gitWorktrees))
        state.cancelScan()
    }

    func testScanProgressMovesForwardOnlyByWholePercents() {
        let state = AppState(performStartupTasks: false, settingsDefaults: defaults)
        state.advanceScanProgress(to: 0.004)
        XCTAssertEqual(state.scanProgress, 0)
        state.advanceScanProgress(to: 0.42)
        XCTAssertEqual(state.scanProgress, 0.42)
        state.advanceScanProgress(to: 0.30)
        XCTAssertEqual(state.scanProgress, 0.42, "a check reported late does not move the bar back")
        state.advanceScanProgress(to: 3)
        XCTAssertEqual(state.scanProgress, 1)
    }
}
