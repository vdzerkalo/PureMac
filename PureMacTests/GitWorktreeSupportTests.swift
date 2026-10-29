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
        XCTAssertEqual(Support.classify(signals { $0.status.ignored = ["config/.env"] }).reasons, [.envFiles])
        XCTAssertEqual(Support.classify(signals { $0.status.untracked = ["a", "b"] }).reasons, [.untrackedFiles(2)])
        XCTAssertEqual(Support.classify(signals { $0.lastActivity = nil }).status, .safeToDelete)
    }

    func testPrunableIsOrphan() {
        let verdict = Support.classify(signals { $0.listed.prunableReason = "" ; $0.status.trackedChanges = 5 })
        XCTAssertEqual(verdict, .init(status: .orphan, reasons: [.prunable]))
        XCTAssertTrue(verdict.status.blocksSelection)
        XCTAssertFalse(Support.Status.needsReview.blocksSelection)
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
        try write(".env\nnode_modules/\n", to: "\(repo!)/.gitignore")
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
        XCTAssertEqual(verdict(envFile), .init(status: .needsReview, reasons: [.envFiles]))
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

        // Once the edit is gone the same item is removed.
        try git(["checkout", "--", "README.md"], in: worktree)
        let cleaned = await engine.cleanItems([item]) { _ in }
        XCTAssertEqual(cleaned.itemsCleaned, 1, "\(cleaned.errors)")
        XCTAssertEqual(cleaned.freedSpace, 1_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }
}

final class WorktreeRemovalRiskTests: XCTestCase {
    func testWorktreesNeedThreeAcknowledgements() {
        XCTAssertTrue(RemovalRisk.requiresAcknowledgement(.gitWorktrees))
        XCTAssertEqual(RemovalRisk.risks(for: .gitWorktrees, items: []).count, 3)
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
