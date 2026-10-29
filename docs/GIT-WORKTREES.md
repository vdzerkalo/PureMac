# Git Worktrees

> The "Git Worktrees" cleanup category: finds leftover git worktrees (AI agents, old branches), judges each by what git reports, removes only through git. Code: `PureMac/Logic/Utilities/GitWorktreeSupport.swift` (`GitWorktreeSupport.classify`), `PureMac/Services/GitWorktreeScanner.swift` (`GitWorktreeScanner`), `PureMac/Services/GitWorktreeSettings.swift`, `PureMac/Services/CleaningEngine.swift` (`removeGitWorktree`), `PureMac/Services/ScanEngine.swift` (`scanGitWorktrees`). Tests: `PureMacTests/GitWorktreeSupportTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Settings](#settings)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Related](#related)

## What it finds

One row per linked worktree. The main worktree of a repository (first entry of `git worktree list`) and bare repositories are never rows. Every row's verdict comes from git; a folder name never decides anything.

Where repositories come from (`GitWorktreeScanner.scan`):

| Source | Detail |
|---|---|
| Claude Code project list | Keys of `projects` in `~/.claude.json`, nothing else in that file (`GitWorktreeSupport.claudeProjectPaths`). |
| `~/.cursor/worktrees`, `~/.codex/worktrees` | Folders with a `.git` entry, up to 3 levels deep, symlinks skipped (`agentWorktreeCandidates`). |
| `<repo>/.claude/worktrees/*` | Direct children with a `.git` entry, symlinks skipped (`claudeWorktreeFolders`). Only used to find orphans. |
| Settings → extra search folders | Folders with a `.git` entry up to 3 levels below each chosen folder (`GitWorktreeScanner.repositoryFolders`): hidden folders, `GitWorktreeSupport.artifactDirectoryNames` folders, symlinks and the inside of a found repository are not walked; at most 20,000 directory entries are read. |

Every hit is resolved to its main repository with `git rev-parse --path-format=absolute --git-common-dir`; then `git -C <repo> worktree list --porcelain -z` lists its worktrees (path, HEAD, branch or detached, `locked`, `prunable`).

A folder under an agent folder that git's list does not contain is an **orphan** (`Reason.notListedByGit`).

Git is `/opt/homebrew/bin/git`, `/usr/local/bin/git`, or `/usr/bin/git` only when developer tools are installed (the shim would otherwise open Apple's installer). Without git the category is empty (`GitWorktreeScanner.locateGit`).

Signals and the command that produces each (all read-only; run as `git -c core.fsmonitor=false -C <dir> …` with `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, 20 s timeout):

| Signal | Source | Used for |
|---|---|---|
| tracked changes | `git status --porcelain=v2 -z --untracked-files=normal --ignored=matching` (worktree); lines `1`, `2`, `u`; unreadable status counts as 1 change | Protected |
| untracked files | same output, lines `?` | Needs review |
| ignored `.env*` | same output, lines `!` whose name starts with `.env` | Needs review |
| ignored artifact folders | same output, `!` lines ending in `/` whose last component is in `artifactDirectoryNames` | size split |
| stash | `git stash list --format=%P%x00%gs%x00` (repository); attributed only when the subject names the worktree's branch, or for a detached worktree when the stash sits on its HEAD | Protected |
| commits on no remote or other branch | `git rev-list --count HEAD --not --exclude=<branch> --branches --remotes`; failure counts as 1 | Protected |
| base ref | Settings override, else `git rev-parse --abbrev-ref origin/HEAD`, else the first existing of `refs/remotes/origin/main`, `refs/remotes/origin/master`, `refs/heads/main`, `refs/heads/master` (`git rev-parse --verify --quiet`) | merged check |
| merged | `git merge-base --is-ancestor HEAD <base>`; else `git cherry <base> HEAD` with no `+` line (catches rebase and cherry-pick merges; squash merges stay "not merged") | Needs review / Safe |
| own work | `git reflog show --format=%gs HEAD` has a commit, merge, rebase, cherry-pick or revert entry | "no commits of its own" |
| locked | `locked` in the worktree list | Protected |
| prunable | `prunable` in the worktree list | Orphan |
| in use | any process whose current directory is inside the worktree (`proc_pidinfo` with `PROC_PIDVNODEPATHINFO`, no `lsof`) | Protected |
| agent worktree | path contains `/.claude/worktrees/`, or is under `~/.cursor/worktrees` or `~/.codex/worktrees` | 24 h rule |
| last activity | newest of: worktree folder mtime, `<repo>/.git/worktrees/<name>/{HEAD,index,logs/HEAD}` mtime, `git log -1 --format=%ct HEAD`, newest file mtime in a walk of at most 20,000 entries that skips `.git` and artifact folders and uses a symlink's own mtime | idle days |

## How it decides

`GitWorktreeSupport.classify` evaluates top to bottom; the first match wins.

| Status | Condition | Selectable | Preselected |
|---|---|---|---|
| Orphan, prunable | git lists it as `prunable` (its folder is gone) | yes, action `git worktree prune` | no |
| Orphan, not listed | folder under an agent folder that git does not list | no, display only | no |
| Protected | any of: tracked changes; commits on no remote or other branch; attributed stash; locked; in use; agent worktree with activity in the last 24 h | no | no |
| Needs review | none of the above and any of: untracked files; ignored `.env*` file; no base ref; not merged into the base; merged but HEAD is the base with no own work; activity within the inactive days setting | yes | no |
| Safe to delete | merged (ancestor of the base, or `git cherry` all applied), clean, nothing untracked, idle for at least the inactive days setting (default 7) | yes | yes |

A fresh worktree whose HEAD equals the base looks merged; it is Needs review ("no commits of its own"), not Safe.

Size is shown as `artifacts X · code Y` in the row and the review sheet. Artifacts are the ignored folders from the table above (`node_modules`, `.next`, `build`, `dist`, `DerivedData`, `.build`, `target`, `.venv`, `venv`, `__pycache__`); code is everything else, hidden files included. Symlinks are neither followed nor counted (`GitWorktreeScanner.measure`).

## How it removes

Every removal runs in `CleaningEngine.removeGitWorktree`. Nothing is moved to the Trash and no file is unlinked by PureMac.

| Row | Command | Freed |
|---|---|---|
| Needs review / Safe to delete | `git -C <repo> worktree remove <path>` (never `--force`; git refuses dirty, untracked or locked worktrees and its message is shown) | scan-time size |
| same, with "Delete the merged branch" on, fresh verdict Safe to delete | afterwards `git -C <repo> branch -d -- <branch>` (never `-D`) | n/a |
| Orphan, prunable | `git -C <repo> worktree prune` | 0 bytes |

Order for a worktree row: re-inspect with the current settings (fresh `git` signals, process list) → refuse if the fresh verdict is Protected or Orphan → `worktree remove` → confirm the folder is gone → optional `branch -d`.

Branch deletion is skipped without a note unless the fresh verdict is Safe to delete. It is skipped with a note when the branch is checked out in any worktree (main one included), is `main`, `master` or the base branch, or git's `-d` refuses (git decides merged-ness against the upstream or the repository's HEAD, so a cherry-picked branch is kept). The worktree removal counts either way.

Prune forgets only git's admin records under `<repo>/.git/worktrees`; no folder is touched. `git worktree prune` has no per-worktree form, so it also forgets that repository's other missing worktrees. Before running it PureMac checks that git still lists the row as prunable, that the folder is still missing (`lstat`), and that no other prunable entry of the repository has a folder again or lies on an unmounted `/Volumes/<name>`; any of these refuses the prune. A row scanned as an ordinary worktree is never pruned, and a prunable row is never turned into a `worktree remove`.

Never touched: the main worktree, branches (unless the setting is on), anything else in `.claude`, `.cursor`, `.codex` (`settings*.json`, `skills`, `rules`, sessions), files outside the worktree that a symlink inside it points to.

Worktrees are not part of Smart Scan, scheduled scans or scheduled cleaning. The review sheet lists each risk for the user to tick, offers a copyable agent brief (`RemovalRisk.agentPrompt`), and a final alert follows.

## Settings

Settings → Cleaning → Git Worktrees (`GitWorktreeSettings`, UserDefaults, read at scan time and again at clean time):

| Setting | Key | Default | Effect |
|---|---|---|---|
| Idle after N days | `settings.cleaning.worktrees.inactiveDays` | 7 (range 1–365) | `classify(inactiveDays:)` |
| Search folders | `settings.cleaning.worktrees.extraRoots` | none | extra repository search roots (absolute paths, `/` rejected) |
| Base branch | `settings.cleaning.worktrees.baseBranch` | empty = automatic order | revision for the merged check; a malformed or unknown name gives no base, so rows are Needs review ("no main branch to compare with") |
| Delete the merged branch | `settings.cleaning.worktrees.deleteMergedBranch` | off | `git branch -d` after a successful removal |

## Safety invariants

1. Classification uses git output only. `GitWorktreeSupport.swift` → `classify`. Test: `GitWorktreeScannerTests.testClassifiesEveryKindOfWorktree`.
2. Protected rows and orphans git does not list can never be selected, in the UI or in the engine. `Models.swift` → `CleanableItem.isSelectionBlocked`, `GitWorktreeSupport.swift` → `Verdict.blocksSelection`, `AppState.swift` → `toggleItem`, `cleanAll`, `CleaningEngine.swift` → `removeGitWorktree`. Tests: `GitWorktreeSupportTests.testOnlyPrunableOrphansCanBeSelected`, `GitWorktreeScannerTests.testOrphanFolderGitDoesNotKnowStaysDisplayOnly`, `testCleaningEngineRechecksBeforeRemoving`.
3. The worktree is re-inspected right before removal, with the settings in force then. `CleaningEngine.swift` → `removeGitWorktree` (`reinspect`, `worktreeSettings`). Test: `GitWorktreeScannerTests.testCleaningEngineRechecksBeforeRemoving`.
4. `git worktree remove` runs without `--force`, and nothing else deletes files. `GitWorktreeScanner.swift` → `remove`. Test: `GitWorktreeScannerTests.testGitRefusesDirtyWorktreeAndReportsWhy`.
5. Removal does not run a repository-wide `git worktree prune`. `GitWorktreeScanner.swift` → `remove`. Test: `GitWorktreeScannerTests.testRemovalNoLongerPrunesOtherMissingWorktrees`.
6. Worktrees are outside Smart Scan, scheduled scans and scheduled cleaning. `Models.swift` → `CleaningCategory.smartScannable`, `AppState.swift` → `cleanAll(scheduled:)`. Test: `WorktreeScheduledCleanupTests.testWorktreesAreNeverPartOfSmartScanOrScheduledCleanup`.
7. Nothing else in `.claude` is touched; `~/.claude.json` is read for the `projects` keys only. `GitWorktreeSupport.swift` → `claudeProjectPaths`. Tests: `GitWorktreeScannerTests.testRemoveDeletesOnlyTheWorktreeAndLeavesClaudeConfigAlone`, `GitWorktreeSupportTests.testClaudeProjectPathsReadsOnlyProjectKeys`.
8. Symlinks are never followed by size, activity or discovery walks, and removal leaves their targets alone. `GitWorktreeScanner.swift` → `measure`, `allocatedBytes`, `newestFileDate`, `repositoryFolders`. Test: `GitWorktreeScannerTests.testSymlinkInsideWorktreeIsNeitherFollowedNorCounted` (the outside folder and its file survive the removal).
9. Branches are deleted only with `-d`, only for a Safe to delete fresh verdict, never when checked out elsewhere or the base branch. `GitWorktreeScanner.swift` → `deleteMergedBranch`. Tests: `testMergedBranchIsDeletedOnlyWhenEnabledAndSafe`, `testBranchIsKeptWhenWorktreeWasNotSafeToDelete`, `testGitDecidesWhetherTheBranchIsMerged`, `testBranchCheckedOutElsewhereOrBaseBranchIsNeverDeleted`.
10. Prune only acts on a row scanned as prunable, only while git lists it as prunable and the folder is missing, and not across an unmounted volume. `GitWorktreeScanner.swift` → `prune`, `unmountedVolume`; `CleaningEngine.swift` → `removeGitWorktree`. Tests: `testPrunableOrphanIsPrunedThroughTheEngine`, `testPruneIsRefusedWhenTheFolderReappeared`, `testPruneRefusedWhenAnotherMissingWorktreeLiesOnAnUnmountedVolume`, `testPruneIsOnlyForTheRowScannedAsPrunable`.
11. The base-branch setting is validated before it reaches git (no leading `-`, no whitespace or revision syntax). `GitWorktreeSupport.swift` → `isValidRevisionName`. Tests: `GitWorktreeSupportTests.testRevisionNamesCannotInjectGitOptions`, `GitWorktreeScannerTests.testBaseBranchOverrideIsHonoured`.
12. The artifact list lives in one place and stays inside the CLI's `Purger.artifactNames` (plus `build`, `dist`). `GitWorktreeSupport.swift` → `artifactDirectoryNames`, `artifactNamesOnlyHere`. Test: `GitWorktreeSupportTests.testArtifactNamesMatchTheCommandLineTool`.

## Failure modes and logs

Logs go to the unified log (subsystem `com.puremac.app`, category `general`) through `Logger.shared`. Row-level failures are also returned as clean errors.

| Symptom | Cause | Where to look |
|---|---|---|
| Category empty | git not found | log `Git Worktrees: git not found` |
| A git call has no result | timeout (20 s) or launch failure | log `git <subcommand> in <dir> failed: <error>` |
| Everything "Needs review: no main branch to compare with" | base-branch setting names no commit in the repository | log `Git Worktrees: base branch <name> not found in <repo>` |
| Row not removed, "Protected: …" | state changed since the scan | log `Skipped worktree <path>: <status> (<reasons>)`; error `<Status>: <reasons> — <name>` |
| Row not removed, "no longer a worktree" | git no longer lists the path | error `<name> is no longer a worktree of <repo>` |
| Row not removed, git message | git refused (dirty, untracked, locked) | log `git worktree remove <path> refused: <git stderr>`; error `<name>: <git stderr>`; also `git worktree remove did not finish` / `git worktree remove failed (exit N)` |
| Removed but folder remains | git exited 0 and the folder is still there | error `<name>: git reported success but the folder is still there` |
| Prune refused, state changed | row scanned as one kind, now the other | log `Skipped worktree <path>: its state changed since the scan`; error `<name>: the folder appeared or disappeared since the scan; rescan first` |
| Prune refused | folder is back, other missing worktree has a folder again, volume unmounted, or git no longer lists it | log `git worktree prune for <path> refused: <reason>`; reasons: `the folder <path> is back; rescan before pruning`, `<path> is on /Volumes/<name>, which is not mounted; mount it or rescan`, `git no longer lists <path> as a missing worktree`, `git worktree prune ran but <path> is still listed`, `git worktree prune did not finish`, `git worktree prune failed (exit N)` |
| Merged branch kept | not Safe to delete, checked out elsewhere, base branch, or `git branch -d` refused | note and log `<name>: branch <b> kept: <reason>` (`checked out in <path>`, `it is the base branch`, git's `error: the branch '<b>' is not fully merged`); shown under the category header |
| Success | | log `Removed worktree <path> (~<bytes> bytes)`, `Pruned missing worktree <path> in <repo>`, `Deleted merged branch <b> in <repo>` |
| Orphan row cannot be removed | not listed by git | error `Not a git worktree PureMac can remove: <name>` |

## Testing

All fixtures are real repositories under `$TMPDIR` (a bare origin, a clone, worktrees); no test touches a real repository.

```
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' -derivedDataPath "$TMPDIR/dd" CODE_SIGNING_ALLOWED=NO
```

One class only: add `-only-testing:PureMacTests/GitWorktreeScannerTests` (fixtures), `GitWorktreeSupportTests` (pure rules), `WorktreeRemovalRiskTests` or `WorktreeScheduledCleanupTests` to that command.

`GitWorktreeScannerTests` builds the repositories (`setUpWithError`), backdates files with `age(_:days:)`, and injects the process list (`scanner.workingDirectories`) and the settings (`CleaningEngine(homeDirectory:worktreeSettings:)`). Settings tests use an isolated `UserDefaults(suiteName:)`.

Manual run against a fake home (create `<fixture-home>/.claude.json` with `{"projects":{"<path of a throwaway repo>":{}}}`; the app then reads that file and that home's preferences):

```
CFFIXED_USER_HOME=<fixture-home> <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac
```

Never point it at a real repository.

## Related

- `PureMac/Logic/Utilities/RemovalRisk.swift`: risk text and agent brief for the review sheet
- `PureMac/Views/CategoryDetailView.swift`: rows, review sheet
- `PureMac/Views/Settings/SettingsView.swift`: Settings section
- `cli/Sources/puremac/Core/Purger.swift`: CLI artifact names the list is kept in sync with
- [Apple features research](APPLE-FEATURES.md): example of the doc layout
