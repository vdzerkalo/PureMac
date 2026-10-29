# Git Worktrees

> The "Git Worktrees" cleanup category: finds leftover git worktrees (AI agents, old branches), judges each by what git reports, removes only through git. Code: `PureMac/Logic/Utilities/GitWorktreeSupport.swift` (`GitWorktreeSupport.classify`), `PureMac/Services/GitWorktreeScanner.swift` (`GitWorktreeScanner`), `PureMac/Services/GitWorktreeSettings.swift`, `PureMac/Logic/Utilities/WorktreeArtifactSupport.swift`, `PureMac/Services/CleaningEngine.swift` (`removeGitWorktree`, `removeWorktreeArtifacts`), `PureMac/Services/ScanEngine.swift` (`scanGitWorktrees`). Tests: `PureMacTests/GitWorktreeSupportTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Build artifacts inside worktrees](#build-artifacts-inside-worktrees)
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

The walk of the ignored folders reads directories with `opendir`/`readdir` (symlinks are never followed), looks for a `.git` entry at any depth (build folders included) and for `.env*` entries outside build folders, and reads at most 400,000 entries per worktree. Hitting the limit, or a folder it cannot read, adds the reason "ignored folders too large to check completely" (Needs review), so such a worktree is never Safe to delete.

Signals and the command that produces each (all read-only; run as `git -c core.fsmonitor=false -C <dir> …` with `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, 20 s timeout):

| Signal | Source | Used for |
|---|---|---|
| tracked changes | `git status --porcelain=v2 -z --untracked-files=normal --ignored=matching` (worktree); lines `1`, `2`, `u`; unreadable status counts as 1 change | Protected |
| untracked files | same output, lines `?` | Needs review |
| ignored `.env*` | same output, lines `!` whose name starts with `.env`; plus a walk of the ignored folders (below) for `.env*` entries outside build folders | Needs review |
| ignored entries outside build folders | same output, every `!` line that is neither a build folder nor inside one (`GitWorktreeSupport.isInsideArtifactFolder`) and not exempt (next row): `config/master.key`, `secrets/`, `vendor/`, a lone `.env` | Needs review ("ignored files outside build folders (n)") |
| exempt ignored entries | never counted by the row above: files named `.DS_Store`, `._*` (AppleDouble), `Icon` + carriage return, `.localized` (`GitWorktreeSupport.isHarmlessIgnoredName`); ignored symlinks (`lstat`: removing the worktree removes the link, never its target, and the walk never follows it); an ignored folder outside the build folders that holds nothing but such files, symlinks and folders of the same kind (`WorkingTreeStatus.harmlessIgnored`, set by `GitWorktreeScanner.inspectIgnoredFolders`; a folder not completely read is never exempt). `.env*` and nested `.git` detection are unchanged and see these entries too | none |
| nested repository in an ignored folder | `GitWorktreeScanner.inspectIgnoredFolders`: a `.git` file or folder anywhere under an ignored folder, build folders included (`node_modules/dep/.git`, `.venv/src/pkg/.git`) | Protected |
| ignored artifact folders | same output, `!` lines ending in `/` whose last component is in `artifactDirectoryNames` | size split |
| stash | `git stash list --format=%P%x00%gs%x00` (repository); attributed only when the subject names the worktree's branch, or for a detached worktree when the stash sits on its HEAD | Protected |
| commits on no remote or other branch | `git rev-list --count HEAD --not --exclude=<branch> --branches --remotes`; failure counts as 1 | Protected |
| base ref | Settings override resolved in the main repository to one full ref (`GitWorktreeScanner.resolveBaseRef`, see Settings), else `git symbolic-ref --quiet refs/remotes/origin/HEAD`, else the first existing of `refs/remotes/origin/main`, `refs/remotes/origin/master`, `refs/heads/main`, `refs/heads/master`; each checked with `git rev-parse --verify --quiet <ref>^{commit}`. Always `refs/heads/*` or `refs/remotes/*`, so it means the same inside every worktree | merged check |
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
| Protected | any of: tracked changes; commits on no remote or other branch; attributed stash; nested repository in an ignored folder; locked; in use; agent worktree with activity in the last 24 h | no | no |
| Needs review | none of the above and any of: untracked files; ignored `.env*` file (also inside ignored folders); any ignored entry outside the build folders; ignored folders not fully checked; no base ref; not merged into the base; merged but HEAD is the base with no own work; activity within the inactive days setting | yes | no |
| Safe to delete | merged (ancestor of the base, or `git cherry` all applied), clean, nothing untracked, no ignored entry outside the build folders (only `node_modules`, `.next`, `build`, … that hold no `.git`; macOS litter and symlinks are exempt), idle for at least the inactive days setting (default 7) | yes | yes |

`git worktree remove` deletes ignored files without asking, and git cannot tell regenerable ones from a `config/master.key`, so only ignored build folders, macOS litter (`.DS_Store`, `._*`, `Icon\r`, `.localized`) and symlinks are allowed in a Safe row.

A fresh worktree whose HEAD equals the base looks merged; it is Needs review ("no commits of its own"), not Safe.

Size is shown as `artifacts X · code Y` in the row and the review sheet. Artifacts are the ignored folders from the table above (`node_modules`, `.next`, `build`, `dist`, `DerivedData`, `.build`, `target`, `.venv`, `venv`, `__pycache__`); code is everything else, hidden files included. Symlinks are neither followed nor counted (`GitWorktreeScanner.measure`).

## How it removes

Every removal runs in `CleaningEngine.removeGitWorktree`. Nothing is moved to the Trash and no file is unlinked by PureMac.

| Row | Command | Freed |
|---|---|---|
| Needs review / Safe to delete | `git -C <repo> worktree remove <path>` (never `--force`; git refuses dirty, untracked or locked worktrees and its message is shown) | scan-time size |
| same, with "Delete the merged branch" on, fresh verdict Safe to delete | afterwards `git -C <repo> branch -d -- <branch>` (never `-D`) | n/a |
| Orphan, prunable | `git -C <repo> worktree prune` | 0 bytes |

Order for a worktree row: re-inspect with the current settings (fresh `git` signals, process list) → refuse if the fresh verdict is worse than the scanned one (a more severe status, or any reason the scan did not report; the error names the new reasons) → refuse if it is Protected or Orphan → `worktree remove` → confirm the folder is gone → optional `branch -d`. A change in a count or a day number alone is not a new reason.

Branch deletion is skipped without a note unless the fresh verdict is Safe to delete. It is skipped with a note when the branch is checked out in any worktree (main one included), is `main`, `master` or the base branch, or git's `-d` refuses (git decides merged-ness against the upstream or the repository's HEAD, so a cherry-picked branch is kept). The worktree removal counts either way.

Prune forgets only git's admin records under `<repo>/.git/worktrees`; no folder is touched. `git worktree prune` has no per-worktree form, so it also forgets that repository's other missing worktrees. Before running it PureMac checks that git still lists the row as prunable, that the folder is still missing (`lstat`), that no other prunable entry of the repository has a folder again or lies on an unmounted `/Volumes/<name>`, and that no worktree was moved rather than deleted (`GitWorktreeScanner.movedWorktreeEvidence`); any of these refuses the prune.

Moved, not deleted: when the repository folder is moved (`mv repo moved`) or a worktree folder is renamed, git lists the worktree as prunable while its folder still exists and its `.git` file still names the admin record `<repo>/.git/worktrees/<name>`. Pruning would delete that record and the folder would answer `fatal: not a git repository`, with its commits unreachable. The prune is refused when any `.git` file found in `<repo>/.claude/worktrees/*`, the agent folders, the Settings search folders, up to four levels inside the repository, or next to a missing worktree's old path names the admin record of a prunable entry, and its git directory is this repository's or no longer exists. The error suggests `git -C <repo> worktree repair <folder>`. Limit: a worktree moved somewhere none of those places covers cannot be told apart from a deleted one; the only protection then is that rows are never preselected and the review sheet says what prune does. A row scanned as an ordinary worktree is never pruned, and a prunable row is never turned into a `worktree remove`.

Never touched: the main worktree, branches (unless the setting is on), anything else in `.claude`, `.cursor`, `.codex` (`settings*.json`, `skills`, `rules`, sessions), files outside the worktree that a symlink inside it points to.

Worktrees are not part of Smart Scan, scheduled scans or scheduled cleaning, and the Overview never counts, selects or cleans them: membership in `CleaningCategory.overviewExcluded` (set b) keeps them out of the Overview total and Clean button (`AppState.overviewSelectedItems`), its category checkbox (`categoryBinding`) and `cleanAll`. They are removable only from their own category screen. The review sheet lists each risk for the user to tick, offers a copyable agent brief (`RemovalRisk.agentPrompt`), and a final alert follows.

## Build artifacts inside worktrees

A worktree that is Needs review or Protected cannot be removed as a whole, but its ignored build folders (`node_modules`, `.next`, `build`, `dist`, `DerivedData`, `.build`, `target`, `.venv`, `venv`, `__pycache__`; `GitWorktreeSupport.artifactDirectoryNames`) are usually most of its size. For each such worktree that has qualifying folders the category shows a second row, **Artifacts in <repo · branch>** (box icon, "Artifacts" badge, indented). It deletes only those folders; the worktree, its tracked and untracked files, its stash and its branch stay, and no git command that writes is run. Code: `PureMac/Logic/Utilities/WorktreeArtifactSupport.swift`, `GitWorktreeScanner.checkArtifactFolder` / `artifactReport`, `CleaningEngine.removeWorktreeArtifacts`. Scope is worktrees only; project-level `node_modules` / Rust `target` cleanup elsewhere in the app (upstream PR #197) is separate and not duplicated here.

Candidates (`WorktreeArtifactSupport.candidates`): a bounded walk of the worktree, at most 4 levels (`a/b/c/node_modules` is the deepest), `.git` skipped, symlinks not followed, a found artifact folder not entered, a folder with its own `.git` (nested repository or nested worktree) not entered, at most 100,000 entries.

Every candidate must pass all of these, at scan time and again right before it is deleted (`checkArtifactFolder`, then `WorktreeArtifactSupport.check` once more immediately before the delete):

| Check | How | Refusal text |
|---|---|---|
| plain relative path, ≤ 4 components, none empty, `.`, `..` or `.git`, last one an artifact name | string rules in `check` | `not a build folder path` |
| a real directory | `lstat`: not a symlink, is a directory | `is a symlink`, `is not a folder` |
| nothing resolves elsewhere | `realpath(<worktree>/<path>)` equals `realpath(<worktree>)` + `/` + path, so no component is a symlink and nothing escapes the worktree | `resolves outside the worktree` |
| same volume | `st_dev` equals the worktree root's | `is on another volume` |
| not inside a repository | no `.git` in a folder between it and the worktree root | `is inside a nested repository` |
| no repository inside | bounded walk of the folder (`GitWorktreeScanner.inspectIgnoredFolders`, at most 400,000 entries, symlinks not followed): any `.git` file or folder at any depth, such as the clone `pip install -e git+…` puts in `.venv/src/<pkg>/.git`. The folder is reported as `nestedRepository` (not just refused), at scan and at clean; a folder too large or unreadable to walk completely is refused | `contains a repository (<relative path of the .git>)`, `is too large or unreadable to check for nested repositories` |
| git ignores it | `git -C <worktree> check-ignore -q -- <path>` exits 0 | `is not ignored by git`, `git check-ignore failed (exit N)` |
| nothing tracked inside | `git -C <worktree> ls-files -- <path>` prints nothing. `check-ignore` already answers "not ignored" for a folder with tracked content (it consults the index), so a tracked `build/` is normally refused by the row above; this check is the second line of defence | `contains files tracked by git` |
| not excluded | `CleanupExclusions` for the worktree and for the folder | `excluded from cleanup` |

Nested repository: if any listed folder holds a `.git`, the row is listed with all its folders and a red "blocked: nested repository in ignored folder (<path>)" reason, and cannot be selected (`WorktreeArtifactsReport.nestedRepository`, `blocker`). At clean time a stale row (the repository appeared after the scan) leaves that folder untouched and reports `<folder>: contains a repository (<path>)`; the row's other folders are still checked one by one. The worktree itself is Protected in that case ("nested repository in ignored folder").

Blocked rows: when the worktree is in use (a process's current directory is inside it), is an agent worktree active in the last 24 hours, or is locked, the row is listed with a red "blocked" reason and cannot be selected (`WorktreeArtifactSupport.blocker`). The same check runs on a fresh `reinspect` before any deletion, so a dev server started after the scan also blocks it. Locked is blocked in addition to the two required cases because a lock means someone asked for the worktree to be left alone.

Selection: artifact rows are never preselected, are skipped by "Select visible" and the category-wide selection (`CleanableItem.requiresExplicitSelection`, part of the single bulk rule `CleanableItem.isExcludedFromBulkSelection`), and are outside Smart Scan, scheduled scans and scheduled cleaning like every worktree row. The review sheet lists each folder with its size, and the risk list gains two entries (permanent delete of regenerable folders; stop dev servers and builds first).

Removal: `CleaningEngine.removeWorktreeArtifacts` is a dedicated route; the generic allow-list is not widened and the row's path (`worktree-artifacts:<worktree path>`) is not a filesystem path, so the generic delete route cannot act on it. Order: exclusion check → worktree still exists (if it is gone, for example removed in the same batch, the row counts as done) → `reinspect` (must still be a worktree git lists, not busy) → per folder `checkArtifactFolder` → `WorktreeArtifactSupport.check` again → bytes measured (`allocatedBytes`, symlinks not counted) → `FileManager.removeItem` on the resolved path → confirm it is gone. Deletion is permanent. A folder that fails a check is left alone and reported; the row counts as cleaned only when every listed folder is gone or already missing. Like all path-based deletion the last check and the delete are not atomic; the repeated filesystem check right before the delete narrows that window.

The artifact row is a part of its worktree's row, so it adds nothing to the category total (`CleanableItem.sizeInCategoryTotal`).

## Settings

Settings → Cleaning → Git Worktrees (`GitWorktreeSettings`, UserDefaults, read at scan time and again at clean time):

| Setting | Key | Default | Effect |
|---|---|---|---|
| Idle after N days | `settings.cleaning.worktrees.inactiveDays` | 7 (range 1–365) | `classify(inactiveDays:)` |
| Search folders | `settings.cleaning.worktrees.extraRoots` | none | extra repository search roots (absolute paths, `/` rejected) |
| Base branch | `settings.cleaning.worktrees.baseBranch` | empty = automatic order | branch for the merged check. Only `refs/heads/*` and `refs/remotes/*` are accepted: a short name is tried as `refs/heads/<name>` and `refs/remotes/<name>` and must match exactly one (`GitWorktreeSupport.baseRefCandidates`). `HEAD`, `@`, pseudo-refs such as `FETCH_HEAD`, tags, `refs/tags/*`, `refs/stash` and commit hashes (4 to 64 hex digits, so a branch named like a hash needs the `refs/heads/` form) are rejected; Settings shows a red message for them. A rejected, unknown or ambiguous name gives no base, so rows are Needs review ("no main branch to compare with") |
| Delete the merged branch | `settings.cleaning.worktrees.deleteMergedBranch` | off | `git branch -d` after a successful removal |

## Safety invariants

1. Classification uses git output only. `GitWorktreeSupport.swift` → `classify`. Test: `GitWorktreeScannerTests.testClassifiesEveryKindOfWorktree`.
2. Protected rows and orphans git does not list can never be selected, in the UI or in the engine. `Models.swift` → `CleanableItem.isSelectionBlocked`, `GitWorktreeSupport.swift` → `Verdict.blocksSelection`, `AppState.swift` → `toggleItem`, `selectAllInCategory`, `cleanAll`, `CleaningEngine.swift` → `removeGitWorktree`. Tests: `GitWorktreeSupportTests.testOnlyPrunableOrphansCanBeSelected`, `GitWorktreeScannerTests.testOrphanFolderGitDoesNotKnowStaysDisplayOnly`, `testCleaningEngineRechecksBeforeRemoving`.
3. The worktree is re-inspected right before removal, with the settings in force then. `CleaningEngine.swift` → `removeGitWorktree` (`reinspect`, `worktreeSettings`). Test: `GitWorktreeScannerTests.testCleaningEngineRechecksBeforeRemoving`.
4. `git worktree remove` runs without `--force`, and nothing else deletes files. `GitWorktreeScanner.swift` → `remove`. Test: `GitWorktreeScannerTests.testGitRefusesDirtyWorktreeAndReportsWhy`.
5. Removal does not run a repository-wide `git worktree prune`. `GitWorktreeScanner.swift` → `remove`. Test: `GitWorktreeScannerTests.testRemovalNoLongerPrunesOtherMissingWorktrees`.
6. Worktrees are outside Smart Scan, scheduled scans and scheduled cleaning. `Models.swift` → `CleaningCategory.smartScannable`, `AppState.swift` → `cleanAll(scheduled:)`. Test: `WorktreeScheduledCleanupTests.testWorktreesAreNeverPartOfSmartScanOrScheduledCleanup`.
6a. The Overview never counts, selects or cleans worktrees, even after the category was scanned on its own screen. `Models.swift` → `CleaningCategory.overviewExcluded`, `AppState.swift` → `isReviewedInCategoryOnly`, `overviewSelectedItems`, `totalSelectedSize`, `categoryBinding`, `cleanAll`, `retryCleanItems`; `DashboardView.swift` → `prepareCleanupConfirmation`. Test: `GitWorktreeScannerTests.testOverviewNeverSelectsCountsOrRemovesScannedWorktrees` (no `worktree remove`, `branch -d` or prune ran).
7. Nothing else in `.claude` is touched; `~/.claude.json` is read for the `projects` keys only. `GitWorktreeSupport.swift` → `claudeProjectPaths`. Tests: `GitWorktreeScannerTests.testRemoveDeletesOnlyTheWorktreeAndLeavesClaudeConfigAlone`, `GitWorktreeSupportTests.testClaudeProjectPathsReadsOnlyProjectKeys`.
8. Symlinks are never followed by size, activity or discovery walks, and removal leaves their targets alone. `GitWorktreeScanner.swift` → `measure`, `allocatedBytes`, `newestFileDate`, `repositoryFolders`. Test: `GitWorktreeScannerTests.testSymlinkInsideWorktreeIsNeitherFollowedNorCounted` (the outside folder and its file survive the removal).
9. Branches are deleted only with `-d`, only for a Safe to delete fresh verdict, never when checked out elsewhere or the base branch. `GitWorktreeScanner.swift` → `deleteMergedBranch`. Tests: `testMergedBranchIsDeletedOnlyWhenEnabledAndSafe`, `testBranchIsKeptWhenWorktreeWasNotSafeToDelete`, `testGitDecidesWhetherTheBranchIsMerged`, `testBranchCheckedOutElsewhereOrBaseBranchIsNeverDeleted`.
10. Prune only acts on a row scanned as prunable, only while git lists it as prunable and the folder is missing, and not across an unmounted volume. `GitWorktreeScanner.swift` → `prune`, `unmountedVolume`; `CleaningEngine.swift` → `removeGitWorktree`. Tests: `testPrunableOrphanIsPrunedThroughTheEngine`, `testPruneIsRefusedWhenTheFolderReappeared`, `testPruneRefusedWhenAnotherMissingWorktreeLiesOnAnUnmountedVolume`, `testPruneIsOnlyForTheRowScannedAsPrunable`.
10a. Prune never cuts loose a worktree that was moved or renamed instead of deleted. `GitWorktreeScanner.swift` → `prune`, `movedWorktreeEvidence`, `gitFileTarget`, `worktreeFolders`. Tests: `GitWorktreeScannerTests.testPruneIsRefusedWhenTheRepositoryFolderWasMoved` (repository moved: a detached worktree with a commit and a staged file survives, `git worktree repair` then works), `testPruneIsRefusedWhenAWorktreeFolderWasRenamed`.
11. The base-branch setting is validated before it reaches git (no leading `-`, no whitespace or revision syntax) and resolved to a full `refs/heads/*` or `refs/remotes/*` ref in the main repository, never inside a worktree; `HEAD`, `@`, pseudo-refs, tags and hashes are rejected. `GitWorktreeSupport.swift` → `isValidRevisionName`, `baseRefCandidates`, `baseBranchSettingProblem`; `GitWorktreeScanner.swift` → `resolveBaseRef`. Tests: `GitWorktreeSupportTests.testRevisionNamesCannotInjectGitOptions`, `testBaseBranchSettingAcceptsOnlyBranchRefs`, `GitWorktreeScannerTests.testBaseBranchOverrideIsHonoured`, `testBaseBranchSettingResolvesToFullBranchRefsOnly`, `testHeadAsBaseBranchNeverMakesUnmergedWorkLookMerged` (unmerged work stays unmerged and its branch is kept).
12a. Ignored work is never deleted from a Safe row: any ignored entry outside the build folders makes the row Needs review, a nested repository (`.git` anywhere under an ignored folder) makes it Protected, and `.env*` inside ignored folders is found. `GitWorktreeSupport.swift` → `ignoredOutsideBuildFolders`, `isInsideArtifactFolder`, `classify`; `GitWorktreeScanner.swift` → `inspectIgnoredFolders`. Tests: `GitWorktreeScannerTests.testIgnoredFilesAndNestedRepositoriesAreNotSafeToDelete` (nested `vendor/lib` commit, `config/master.key`, `secrets/.env` all survive), `testMacOSLitterAndIgnoredSymlinksKeepAWorktreeSafe` (only `.DS_Store`, `._x`, `Icon\r`, `.localized`, a litter-only folder and ignored symlinks: Safe and removed, symlink targets intact; one extra ignored `notes.txt`, or a `notes.txt` inside the folder: Needs review), `testIgnoredFolderWalkIsBoundedAndNeverFollowsSymlinks`, `GitWorktreeSupportTests.testIgnoredEntriesOutsideBuildFoldersNeedReview`, `testMacOSLitterAndHarmlessEntriesDoNotCountAsIgnoredWork`, `testNestedRepositoryInIgnoredFolderIsProtected`.
12b. A row whose fresh verdict is worse than the scanned one, or has a reason the scan lacked, is not removed. `GitWorktreeSupport.swift` → `Verdict.isWorse`, `reasonsAdded`; `CleaningEngine.swift` → `removeGitWorktree`. Tests: `GitWorktreeScannerTests.testEngineRefusesAWorktreeThatGotWorseSinceTheScan`, `GitWorktreeSupportTests.testAWorseVerdictAtRecheckIsDetected`.
12. The artifact list lives in one place and stays inside the CLI's `Purger.artifactNames` (plus `build`, `dist`). `GitWorktreeSupport.swift` → `artifactDirectoryNames`, `artifactNamesOnlyHere`. Test: `GitWorktreeSupportTests.testArtifactNamesMatchTheCommandLineTool`.
13. Artifact cleaning deletes only folders that are real directories (never symlinks), whose realpath is the worktree's realpath plus the relative path, on the worktree's volume. `WorktreeArtifactSupport.swift` → `check`. Tests: `GitWorktreeScannerTests.testSymlinkedAndEscapingArtifactFoldersAreRefused` (symlinked folder, folder behind a symlinked parent and a symlink into the worktree itself are refused; outside files survive), `testPathsThatAreNotPlainBuildFoldersAreRefused`.
14. Artifact cleaning requires git to ignore the folder and no tracked file inside, re-checked right before the delete. `GitWorktreeScanner.swift` → `checkArtifactFolder`. Tests: `testTrackedOrUnignoredBuildFoldersAreRefused` (tracked `build/`, unignored `dist/`), `testFolderBecomingTrackedAfterTheScanIsLeftAlone`. The `ls-files` check has no test of its own: git's `check-ignore` refuses first.
15. Artifact rows of a worktree in use, locked or active as an agent worktree are blocked, at scan time and at clean time. `WorktreeArtifactSupport.swift` → `blocker`; `CleaningEngine.swift` → `removeWorktreeArtifacts`. Tests: `testBusyWorktreesBlockArtifactRows`, `testEngineRefusesWorktreesThatBecameBusyAfterTheScan` (a real child process with its working directory in the worktree).
16. The worktree, its tracked files and its uncommitted edits are untouched by artifact cleaning, and a folder is removed without its parents. `CleaningEngine.swift` → `removeWorktreeArtifacts`. Test: `testIgnoredBuildFoldersAreRemovedAndTheWorktreeStaysIntact` (compares `git status --porcelain` and file contents before and after, for a Needs review and a Protected worktree).
17. Nested repositories and nested worktrees are neither walked nor deleted into, and no build folder that holds a `.git` at any depth is deleted: the row is blocked at scan and the folder is left alone at clean. `WorktreeArtifactSupport.swift` → `candidates`, `check`, `WorktreeArtifactsReport.blocker`; `GitWorktreeScanner.swift` → `inspectIgnoredFolders`, `artifactReport`; `CleaningEngine.swift` → `removeWorktreeArtifacts`. Tests: `testCandidateWalkIsBoundedAndDoesNotCrossRepositories`, `testNestedRepositoriesInsideAWorktreeAreNotWalkedOrDeleted`, `testRepositoryDeepInsideABuildFolderBlocksTheRowAndIsNeverDeleted` (`.venv/src/pkg/.git` and a `.git` file under `node_modules`; no file in either folder is deleted), `testBuildFolderWithoutRepositoriesIsStillRemoved` (`.gitignore` and `.github` are not repositories).
18. Artifact rows are never preselected, never bulk-selected, never scheduled, and their path cannot reach the generic delete route. `Models.swift` → `CleanableItem.requiresExplicitSelection`, `isExcludedFromBulkSelection`, `isActionItem`; `AppState.swift` → `cleanAll(scheduled:)`. Tests: `WorktreeScheduledCleanupTests.testArtifactRowsAreNeverPreselectedBulkSelectedOrScheduled`, `CategoryRulesTests.testTheBulkRuleSkipsEveryHandOnlyBlockedAndRunningAppRow`, `testIgnoredBuildFoldersAreRemovedAndTheWorktreeStaysIntact`.
19. A row whose worktree git does not list is not cleaned. `CleaningEngine.swift` → `removeWorktreeArtifacts` (`reinspect`). Test: `testArtifactRowsFollowTheirWorktreeAndAreAnOrphanOnlyWhenGone`.

## Failure modes and logs

Logs go to the unified log (subsystem `com.puremac.app`, category `general`) through `Logger.shared`. Row-level failures are also returned as clean errors.

| Symptom | Cause | Where to look |
|---|---|---|
| Category empty | git not found | log `Git Worktrees: git not found` |
| A git call has no result | timeout (20 s) or launch failure | log `git <subcommand> in <dir> failed: <error>` |
| Everything "Needs review: no main branch to compare with" | base-branch setting is not a branch name, names no branch in the repository, or matches both a local and a remote-tracking branch | log `Git Worktrees: base branch <name> is not a branch name`, `… not found in <repo>` or `… is ambiguous in <repo>` |
| Row "Needs review: ignored folders too large to check completely" | more than 400,000 entries in the ignored folders, or one could not be read | none (the reason is the row's verdict) |
| Row not removed, "changed since the scan" | the fresh verdict is worse than the scanned one or has a new reason | log `Skipped worktree <path>: worse than at the scan (<status>: <reasons>)`; error `<name>: changed since the scan (<Status>: <new reasons>); rescan first` |
| Row not removed, "Protected: …" | state changed since the scan | log `Skipped worktree <path>: <status> (<reasons>)`; error `<Status>: <reasons> — <name>` |
| Row not removed, "no longer a worktree" | git no longer lists the path | error `<name> is no longer a worktree of <repo>` |
| Row not removed, git message | git refused (dirty, untracked, locked) | log `git worktree remove <path> refused: <git stderr>`; error `<name>: <git stderr>`; also `git worktree remove did not finish` / `git worktree remove failed (exit N)` |
| Removed but folder remains | git exited 0 and the folder is still there | error `<name>: git reported success but the folder is still there` |
| Prune refused, state changed | row scanned as one kind, now the other | log `Skipped worktree <path>: its state changed since the scan`; error `<name>: the folder appeared or disappeared since the scan; rescan first` |
| Prune refused, moved worktree | a folder that still exists points at a record the prune would delete (repository or worktree folder moved or renamed) | error `<folder> still exists and points at git's record <name> of <repo>. It was moved or renamed, not deleted; pruning would break it. Run: git -C <repo> worktree repair <folder>` |
| Prune refused | folder is back, other missing worktree has a folder again, volume unmounted, or git no longer lists it | log `git worktree prune for <path> refused: <reason>`; reasons: `the folder <path> is back; rescan before pruning`, `<path> is on /Volumes/<name>, which is not mounted; mount it or rescan`, `git no longer lists <path> as a missing worktree`, `git worktree prune ran but <path> is still listed`, `git worktree prune did not finish`, `git worktree prune failed (exit N)` |
| Merged branch kept | not Safe to delete, checked out elsewhere, base branch, or `git branch -d` refused | note and log `<name>: branch <b> kept: <reason>` (`checked out in <path>`, `it is the base branch`, git's `error: the branch '<b>' is not fully merged`); shown under the category header |
| Success | | log `Removed worktree <path> (~<bytes> bytes)`, `Pruned missing worktree <path> in <repo>`, `Deleted merged branch <b> in <repo>` |
| Orphan row cannot be removed | not listed by git | error `Not a git worktree PureMac can remove: <name>` |
| Artifact row not cleaned, worktree busy | in use, locked, or active agent worktree | log `Skipped artifacts in <worktree>: <reason>`; error `<row name>: <reason>` (reasons: `open in a running process`, `locked by git`, `agent worktree active in the last 24 hours`) |
| Artifact row not cleaned, worktree not listed | git no longer lists the worktree | error `<row name>: <worktree> is no longer a worktree of <repo>` |
| Artifact folder left alone | a check failed | log `Left artifact folder <path>: <refusal>`; error `<row name>: <relative path>: <refusal>; …` with the refusal texts from the table above (`contains a repository (<path>)` for a nested repository) |
| Artifact row blocked, nested repository | a listed folder holds a `.git` | red "blocked: nested repository in ignored folder (<path>)" on the row; nothing to look up in the log |
| Artifact folder not deleted | filesystem error or changed under us | log `Could not delete artifact folder <path>: <error>`; error entries `<relative path>: <error>`, `<relative path>: changed while being checked`, `<relative path>: still there after deleting`, `<relative path>: excluded from cleanup` |
| Artifact success | | log `Deleted artifact folder <path> (~<bytes> bytes)` |
| Artifact row refused up front | excluded worktree, or not an artifact row | error `Excluded from cleanup: <row name>`, `Not a worktree artifact row: <row name>` |

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

- `PureMac/Logic/Utilities/WorktreeArtifactSupport.swift`: build-folder rules ([section above](#build-artifacts-inside-worktrees))
- `PureMac/Logic/Utilities/RemovalRisk.swift`: risk text and agent brief for the review sheet
- `PureMac/Views/CategoryDetailView.swift`: rows, review sheet
- `PureMac/Views/Settings/SettingsView.swift`: Settings section
- `cli/Sources/puremac/Core/Purger.swift`: CLI artifact names the list is kept in sync with
- [Apple features research](APPLE-FEATURES.md): example of the doc layout
