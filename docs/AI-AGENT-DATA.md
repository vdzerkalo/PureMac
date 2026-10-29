# AI Agent Data

> Review-only category listing large, regenerable data of AI agent apps (Claude Desktop, Codex, Antigravity, Cursor). Rows are never selected, never in Smart Scan or scheduled cleaning, and are moved to the Trash only while the owning app is not running. Code: `PureMac/Logic/Utilities/AIAgentDataSupport.swift` (`AIAgentDataSupport`), `PureMac/Services/CleaningEngine.swift` (`trashAIAgentDataItem`, `TrashOperation`), `PureMac/Services/ScanEngine.swift` (`scanAIAgentData`). Tests: `PureMacTests/AIAgentDataTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Evidence](#evidence)
- [Related](#related)

## What it finds

Sidebar: Tools > Developer Cleanup > AI Agent Data (`CleaningCategory.aiAgentData`, raw value `AI Agent Data`). The scan runs only when the user opens the category and presses Scan. Paths are relative to the current user's home (symlink-resolved, `AIAgentDataSupport.canonicalHomeDirectory`). No environment variable is read.

| Rule id | Path template | Owner | Needs |
|---|---|---|---|
| `claude.simulator.deriveddata` | `Library/Application Support/Claude/simulator-builds/<hex id>/DerivedData` | Claude Desktop | none |
| `claude.cache` | `Library/Application Support/Claude/Cache` | Claude Desktop | none |
| `claude.codecache` | `Library/Application Support/Claude/Code Cache` | Claude Desktop | none |
| `codex.pluginbackup` | `.codex/.tmp/plugins-backup-<6 letters or digits>` | Codex | no `~/.codex/.tmp/plugins.sync.lock` (any file type), and the folder's own modification date at least 1 hour old |
| `antigravity.backup.recordings` | `.gemini/antigravity-backup/browser_recordings` | Antigravity | real directory `.gemini/antigravity/browser_recordings`, and every top-level entry name of the backup folder exists there as a non-symlink (names only, contents are not compared) |
| `cursor.vsix` | `Library/Application Support/Cursor/CachedExtensionVSIXs` | Cursor | none |

`<hex id>` is 8 to 64 lowercase hex characters. Entries smaller than 1 MB are not listed. The Claude Desktop VM disk image (`vm_bundles/.../rootfs.img`) is deliberately not a rule; see [Excluded](#excluded). A row whose Needs column fails is not listed, and is refused with the reason if its item is submitted for removal.

Not duplicated here:
- `AI Apps` (`scanAIApps`) covers only Ollama and LM Studio.
- `cli/Sources/puremac/Core/Catalog.swift` lists `Cursor (cache)`: `Library/Application Support/Cursor/{Cache,CachedData,logs}`. This category does not list those three.
- `~/.cursor/worktrees` and `~/.codex/worktrees` belong to the worktree category.

## How it decides

| Row | Condition | Selectable | Preselected |
|---|---|---|---|
| Any listed row, owner not running | path matches a rule, no symlink, expected type, rule needs met | yes | never |
| Any listed row, owner running | process check below is true | no (checkbox disabled, warning line, left out of the selection) | never |
| Path not in the table | `AIAgentDataSupport.rule(forPath:)` returns nil | not listed | n/a |
| Codex plugin backup while `plugins.sync.lock` exists or younger than 1 hour | requirement fails | not listed | n/a |
| Antigravity backup with an entry the live `browser_recordings` lacks, or no live folder | requirement fails | not listed | n/a |
| Anything under `~/.claude` or `~/.claude.json` | `isProtectedAgentLocation` | never listed, never removable | n/a |

Owner running (`AIAgentDataSupport.liveOwnerRunningCheck`, `Owner.matches`): true when `NSRunningApplication` finds the owner's bundle identifier, or any process matches the owner by executable path (`proc_listallpids` + `proc_pidpath`). Two rules for unreadable data:
- If the whole process list cannot be read, the owner counts as running.
- If one process's path cannot be read, its name (`proc_name`) is compared with the owner's name prefixes, case-insensitive (`Claude`, `Codex`, `Antigravity`, `Cursor`); a match counts as running. A process whose path and name are both unreadable (another user's) is ignored. That is the remaining gap.

| Owner | Bundle identifier | Executable path prefixes |
|---|---|---|
| Claude Desktop | `com.anthropic.claudefordesktop` | `/Applications/Claude.app/`, `~/Library/Application Support/Claude/` |
| Codex | `com.openai.codex` (ChatGPT.app) | `/Applications/ChatGPT.app/`, `/Applications/Codex.app/`, `~/.codex/`; any path containing `/@openai/codex` (Homebrew, npm and nvm installs); any executable named `codex` |
| Antigravity | `com.google.antigravity` | `/Applications/Antigravity.app/`, `~/.gemini/` |
| Cursor | `com.todesktop.230313mzl4w4u92` | `/Applications/Cursor.app/`, `~/.cursor/` |

Matching is by executable path. The `claude` CLI that Claude Desktop manages under `~/Library/Application Support/Claude/claude-code/<version>/.../claude` is under the Claude prefix and blocks Claude Desktop rows. A Claude Code CLI installed elsewhere (for example `~/.local/share/claude/versions/...`) does not, unless its path is unreadable and its name starts with `Claude`. The ChatGPT.app prefix blocks Codex rows while the ChatGPT app is open. A Codex CLI run through `node` is detected through the `codex` child process, not the `node` parent.

Review UI (`CategoryDetailView`): each row shows its name, a one-line description (`CleanableItem.detail`) and, when the owner runs, `<App> is running. Quit it to remove this.` The running set is refreshed on appear and every 3 seconds.

## How it removes

- Action: `CleaningEngine.trashAIAgentDataItem` validates once, immediately before the move, then calls the injected `TrashOperation` on the validated URL. The default (`CleaningEngine.systemTrash`) is `FileManager.trashItem(at:resultingItemURL:)`; tests inject a fake that moves into a temp folder. Review label: `Move to Trash` (`CategoryDetailView.removalMethod`).
- Entry point: Review removal > Remove in the category view (`AppState.cleanCategory`). The dashboard "Clean all" and scheduled cleaning never include these rows (`AppState.allResults` uses `CleaningCategory.smartScannable`).
- No `removeItem`, no administrator escalation (`cleanWithAdminPrivileges` refuses the category), no shell command.
- The generic `isSafeToDelete` allowlist is not consulted and was not widened. The exact templates in `AIAgentDataSupport.rules` are the allowlist for this category.
- Space is not returned until the Trash is emptied. An item that no longer exists is dropped from the list without counting freed bytes.
- Never touched: credentials, settings, chat or session history, VM identity and `sessiondata.img`, installed apps or runtimes, `~/.claude`, `~/.claude.json`. See [Evidence](#evidence).

## Safety invariants

1. Review-only. `CleaningCategory.reviewOnly`, `smartScannable`; `AppState.allResults`, `startSmartScan`, `runScheduledScan`, `ScheduleConfig.categoriesToScan`, `AppState.junkTotalSize`. Tests: `testCategoryIsReviewOnlyAndOutsideSmartScanAndSchedules`, `testCleanAllAndTotalsIgnoreReviewOnlyResults`.
2. Every row unselected. `ScanEngine.scanAIAgentData` sets `isSelected: false`. Test: `testScanListsOnlyAllowlistedShapesAndLeavesEveryRowUnselected`.
3. Exact allowlist, no prefix matching. `AIAgentDataSupport.rules`, `validate`. A deeper or sibling path (`Cache/Cache_Data`, `sessiondata.img`, `auth.json`, `snapshots`) is refused. Tests: `testRuleShapesAreExact`, `testPathsOutsideTheAllowlistAreRefusedEvenInsideAnAllowlistedAppFolder`.
4. `~/.claude` and `~/.claude.json` are never produced and never removable, even if a forged item names them. `AIAgentDataSupport.isProtectedAgentLocation`. Tests: `testScanNeverProducesClaudeCodeDataEvenWhenItIsHuge`, `testClaudeCodeDataIsNeverRemovedEvenWhenTheItemIsForged`.
5. Symlinks. Every component from home to the item is checked with `lstat` semantics (`attributesOfItem`), and `resolvingSymlinksInPath` must equal the path. Wildcard expansion lists only real directories. Tests: `testSymlinkedCandidatesAreNotScanned`, `testSymlinkedCandidateIsRefusedAndTargetSurvives`, `testSymlinkedParentIsRefused`.
6. Regenerable only. The Codex backup needs no sync lock and an age of one hour; the Antigravity backup needs every top-level entry name present in the live folder. `Requirement` (`noFile`, `olderThan`, `entriesExist`) in `AIAgentDataSupport`. These are re-evaluated at removal time. Tests: `testCodexPluginBackupIsBlockedBySyncLockAndByRecentModification`, `testAntigravityBackupIsOnlyListedWhenEveryEntryExistsInTheLiveCopy`, `testAntigravityBackupIsRefusedAtRemovalWhenALiveEntryDisappears`, `testAntigravityBackupIsOnlyListedWhenTheLiveCopyExists`.
7. Blocked while the owner runs. `AIAgentDataSupport.validateForRemoval`, `Owner.matches`, `liveOwnerRunningCheck` (fails closed when the process list is unreadable; unreadable single paths fall back to the name). Tests: `testRemovalIsBlockedWhileTheOwningAppRuns`, `testAppStartedAfterTheScanBlocksRemoval`, `testCodexCLIIsDetectedWhereverItIsInstalled`, `testClaudeDesktopMatchesItsManagedCLIButNotAnotherCLIInstall`, `testUnreadablePathFallsBackToTheProcessNameAndFailsClosed`, `testLiveProcessListContainsTheRunningTestHost`.
8. Validated at removal time, once, immediately before the move. `CleaningEngine.trashAIAgentDataItem` runs `validateForRemoval` (shape, symlinks, real path, requirements, fresh process list) and passes the validated URL to `TrashOperation`. The scan validated the same rules earlier; the removal does not trust that result. Remaining window: between the last check and `trashItem` (milliseconds) a process running as the same user could replace a path component with a symlink. `trashItem` then follows the replaced parent. Closing it needs `openat`/`renameat` with `O_NOFOLLOW` on every component and a hand-built Trash move (no Put Back metadata); that was not implemented or verified. An attacker with that access can already delete the user's files directly. Test: `testRemovalValidatesAtMoveTimeAndNeverTouchesTheRealTrash` (one validation per item, at removal).
9. Trash only, no admin. `TrashOperation`; `cleanWithAdminPrivileges` guard. Tests: `testRemovalValidatesAtMoveTimeAndNeverTouchesTheRealTrash`, `testAdministratorCleaningNeverEscalatesAIAgentData`.
10. A vanished item reports nothing and counts no bytes. Test: `testAlreadyGoneItemIsNotCountedAsFreedSpace`.
11. Small entries (under 1 MB) are not listed. Test: `testSmallItemsAreSkipped`.
12. Bulk selection never selects a blocked row. `AppState.isBlockedByRunningApp`, `toggleItem`, `selectAllInCategory`, `isItemSelected`, `setRunningAIAgentOwners` (also drops existing selections of rows that become blocked); "Select visible" in `CategoryDetailView` works on the unblocked rows only. Test: `testBulkSelectionSkipsRowsBlockedByARunningApp`.
13. The VM disk image and everything else outside the table is refused. Tests: `testVMDiskImagesAreNeverListedEvenWithTheirCompressedSource`, `testVMDiskImageIsRefusedEvenWithItsCompressedSource`.
14. No test uses the real Trash. `makeEngine` in `AIAgentDataTests` always injects a fake `TrashOperation`.

## Failure modes and logs

Logs go through `Logger.shared`.

| Symptom | Cause | Where to look |
|---|---|---|
| Row has a warning and no checkbox | owning app or one of its helper processes is running | quit the app; `AIAgentDataSupport.liveOwnerRunningCheck` |
| Alert `Skipped AI agent data: <App> is running: <path>` | app started after the scan | log prefix `Skipped AI agent data:` |
| `Skipped AI agent data: path or a parent is a symbolic link` | a parent or the item was replaced by a link | log prefix `Skipped AI agent data:` |
| `Skipped AI agent data: the live copy it duplicates is missing` | live `~/.gemini/antigravity/browser_recordings` is gone | Needs column above |
| `Skipped AI agent data: it holds entries that the live copy does not` | the Antigravity backup has an entry missing (or symlinked) in the live folder | Needs column above |
| `Skipped AI agent data: a sync lock file exists` | `~/.codex/.tmp/plugins.sync.lock` exists. Codex leaves it behind (0 bytes on this Mac since 10 Jun), so the Codex row stays hidden until Codex removes it | Needs column above |
| `Skipped AI agent data: it was modified less than an hour ago` | Codex plugin backup is younger than 1 hour | Needs column above |
| `Skipped AI agent data: path is not an allowlisted AI agent data location` | forged or stale item | `AIAgentDataSupport.rules` |
| `Skipped AI agent data: path is in a protected agent location` | item under `~/.claude` | by design |
| `<name> at <path>: <error>` and `Clean failed:` | `trashItem` failed (permissions, no Trash on the volume) | log prefix `Clean failed:` |
| Row missing after a scan | under 1 MB, rule not met, or symlink | run the tests in [Testing](#testing) |
| Row blocked on a Mac with ChatGPT open | ChatGPT.app hosts Codex | by design |
| Disk space unchanged after removal | items are in the Trash | empty the Trash |

## Testing

```
xcodegen generate
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/fork-ai-agent-data-dd" CODE_SIGNING_ALLOWED=NO \
  -only-testing:PureMacTests/AIAgentDataTests
```

- Fixtures are temp homes under `$TMPDIR`; `tearDown` removes only those homes (the fake trash folders are temp homes too).
- The owning-app check and the Trash move are injected: `CleaningEngine(homeDirectory:isAIAgentOwnerRunning:trashOperation:)`. Tests never depend on which apps run on the machine and never touch `~/.Trash`. `Owner.matches` is tested with synthetic `ProcessEntry` values; `liveProcesses()` is tested against the test runner's own path.
- Manual run against a fake home (build with the command above, create the fixture folders from the table in [What it finds](#what-it-finds) with files over 1 MB):
  `CFFIXED_USER_HOME=<fixture-home> <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac`
  Rows for Claude Desktop and Codex stay blocked while the real Claude.app or ChatGPT.app runs, because the `/Applications/...` prefixes are real paths.

## Evidence

Read-only inspection on 2026-10-29 (names, sizes, mtimes, file types; no file contents opened). Process list at that time: Claude.app and its helpers (including `claude-ios-sim`) and ChatGPT.app with the Codex framework and `codex` CLI were running; Antigravity and Cursor were not. `~/.claude` and `~/.claude.json` were not inspected.

### Included

| Path | What it is | Why included |
|---|---|---|
| `~/Library/Application Support/Claude/simulator-builds/<id>/DerivedData` | 9.2 GB. Standard Xcode layout: `Build`, `CompilationCache.noindex`, `Logs`, `ModuleCache.noindex`, `SDKExplicitPrecompiledModules`, `SDKStatCaches.noindex`, `info.plist`. Sibling `logs/` holds one 26 MB build log | Build output of Claude's iOS Simulator tool (inferred from the folder name, the Xcode layout and the `claude-ios-sim` helper). Rebuilt by the next build |
| `~/Library/Application Support/Claude/Cache` (1.2 GB), `Code Cache` (372 MB) | Standard Chromium cache directory names in an Electron app | Disposable by definition; rebuilt on launch |
| `~/.codex/.tmp/plugins-backup-<id>` (7 folders, 21 to 56 MB, 277 MB total) | Each holds `.git`, `.agents`, `plugins`, `README.md`; mtimes 27 May to 6 Jun 2026; `.tmp/plugins` (93 MB) is the active copy | Stale copies of the plugin sync folder. Hidden while `~/.codex/.tmp/plugins.sync.lock` exists (it exists on this Mac, 0 bytes, 10 Jun) or when younger than 1 hour |
| `~/.gemini/antigravity-backup/browser_recordings` | 5.2 GB: 37,380 `.jpg` frames and one `.json` in one session-UUID folder. The same UUID exists in the live `~/.gemini/antigravity/browser_recordings` (6.7 GB). The backup folder was written in one second (28 Oct 23:02:53) | Duplicate of live data inside a backup. The row requires every top-level entry name of the backup to exist in the live folder. This is a name check: the live copy of the shared UUID is larger (6.7 GB against 5.2 GB), and contents are not compared |
| `~/Library/Application Support/Cursor/CachedExtensionVSIXs` | 97 MB of downloaded extension packages | Standard VS Code-family download cache. `Cache`, `CachedData`, `logs` are already in the CLI catalog and are not repeated |

### Excluded

| Path | What it is | Why excluded |
|---|---|---|
| `~/.claude`, `~/.claude.json` | Claude Code data | Never touched or listed (upstream incident #51) |
| `Claude/vm_bundles/claudevm.bundle/sessiondata.img` (233 MB), `efivars.fd`, `machineIdentifier`, `macAddress`, `gvisorMacAddress`, `vmIP`, `.cowork-adopted` | VM session data and identity | Session data and VM identity |
| `Claude/vm_bundles/claudevm.bundle/rootfs.img` (10 GB) | Root disk of the Claude Desktop VM, mtime 28 Oct; the compressed `rootfs.img.zst` (1.2 GB) is dated 26 Oct | Dropped after review. The image is newer than its compressed copy, so the VM writes to it and removing it would lose in-VM changes. The VM runs as `com.apple.Virtualization.VirtualMachine.xpc`, which Docker also uses, so a running VM cannot be tied to Claude reliably |
| `Claude/vm_bundles/claudevm.bundle/{initrd*,vmlinuz*,rootfs.img.zst}` and `.origin` markers | Boot components and compressed originals | Part of the VM bundle (see `rootfs.img`); each under 60 MB except the 1.2 GB `.zst` |
| `Claude/vm_bundles/warm` | Two empty folders | Nothing to reclaim |
| `Claude/local-agent-mode-sessions` (212 MB), `claude-code-sessions` (40 MB), `git-shadow`, `side-session-notes`, `pending-uploads` | Agent sessions and notes | Sessions and history |
| `Claude/claude-code` (525 MB) | Claude Code binaries launched by the app | In use, not a cache |
| `Claude/claude-code-vm` (280 MB), `Claude Extensions` (363 MB) | VM support files, installed extensions | Cannot be identified as regenerable |
| `Claude/{Partitions,Cookies,IndexedDB,Local Storage,Session Storage,config.json,claude_desktop_config.json*}` | Login state and settings | Credentials and settings |
| `~/.codex/auth.json`, `config.toml*`, `history.jsonl`, `thread_history_1.sqlite` (735 MB), `state_5.sqlite`, `sessions`, `archived_sessions`, `session_index.jsonl`, `memories*`, `dictation-history`, `transcription-history.jsonl` | Credentials, settings, history | Credentials, settings, history |
| `~/.codex/packages/standalone` (679 MB), `plugins` (434 MB), `.tmp/plugins`, `computer-use` (73 MB) | Active runtime (`current` links to release 0.165.0), plugins and helper app | In use |
| `~/.codex/cache` (55 MB) | Folders named `bundled_plugin_exclusions`, `codex_app_directory`, `codex_apps_server_info`, `codex_apps_tools`, `remote_plugin_catalog` | Contents not identifiable without opening files; small |
| `~/.codex/worktrees` | Agent git worktrees | Separate worktree category |
| `~/.gemini/oauth_creds.json`, `google_accounts.json`, `settings.json`, `trustedFolders.json`, `installation_id` | Credentials and settings | Credentials and settings |
| `~/.gemini/antigravity` (8.6 GB), `antigravity-ide` (8.6 GB) | Live Antigravity data (`conversations`, `brain`, `knowledge`, ...); `antigravity-ide` was written at the same second as the backup | Live data, or cannot be told apart from it |
| `~/.gemini/antigravity-browser-profile` (2.1 GB) | Browser profile | Cookies and logins |
| `~/.gemini/antigravity-backup/{mcp_config.json,user_settings.pb,installation_id,playground}` | Backup copies of MCP config, settings, id, empty scratch folders | Config may hold tokens; settings |
| `~/Library/Application Support/Cursor/snapshots/stores` (9.8 GB) | Three content-addressed stores (`objects`, `baseline.marker`, `secondary-index-baseline`, lock files) | Looks like the workspace snapshot store behind agent checkpoints. Cannot be shown rebuildable. Largest remaining item; needs a decision from someone who knows Cursor's recovery behaviour |
| `~/Library/Application Support/Cursor/{User,AgentStores,Backups,Cookies,Local Storage,Partitions}` | Settings, agent stores, login state | Settings, history, credentials |
| `~/.cursor/extensions` (1.5 GB), `projects`, `plans`, `ai-tracking`, `mcp.json`, `skills*` | Installed extensions, project data, MCP config | Installed or user data |
| `~/.cursor/worktrees` (3.1 GB) | Agent git worktrees | Separate worktree category |
| `~/Library/Application Support/Antigravity/{Cache (634 MB),CachedData (408 MB),logs (107 MB)}` | Same shape as Cursor's `Cache`, `CachedData`, `logs` | Outside the requested scope; belongs with the CLI catalog entry for the same shape |

## Related

- [Apple feature and storage research](APPLE-FEATURES.md)
- `PureMac/Models/Models.swift` (`CleaningCategory.reviewOnly`, `smartScannable`)
- `PureMac/Views/CategoryDetailView.swift` (`blockedOwner`, `removalMethod`)
- `PureMac/Logic/Utilities/XcodeBuildMCPDerivedDataSupport.swift` (the Move to Trash pattern this follows)
- `cli/Sources/puremac/Core/Catalog.swift` (`Cursor (cache)`)
