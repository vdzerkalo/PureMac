# Local AI Models

> Lists Ollama models and Hugging Face downloads one row per model and removes them only through Ollama itself (its API, or `ollama rm` when the API is unreachable), `hf cache rm` or one validated folder delete. Not part of Smart Scan unless the user adds it; never part of scheduled scans or cleaning. Code: `PureMac/Logic/Utilities/LocalAIModelsSupport.swift` (`LocalAIModelsSupport`), `PureMac/Services/LocalAIModelsService.swift` (`LocalAIModels`, `LocalAIModelsContext`). Tests: `PureMacTests/LocalAIModelsTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Related](#related)

## What it finds

Sidebar: Tools -> Developer Cleanup -> Local AI Models (`CleaningCategory.localAIModels`, raw value `Local AI Models`). Scan runs only when the user opens the page and presses Scan, or Rescan.

| Source | Where | Row |
|---|---|---|
| Ollama | `GET <OLLAMA_HOST>/api/tags` (default `http://127.0.0.1:11434`). Redirects are refused. `ollama list` from the first existing of `/usr/local/bin/ollama`, `/opt/homebrew/bin/ollama`, `/Applications/Ollama.app/Contents/Resources/ollama` runs instead when the request fails without timing out, answers any status other than 200, or returns a body that is not the `{"models":[...]}` shape. A timed-out request does not fall back. | One per model. Name `qwen3.5:35b`, size in bytes from the API (decimal units parsed from the table for CLI rows), modified date from `modified_at` (CLI rows have no date: the table only has "6 months ago"). Path is the virtual `ollama-model:<name>#<digest>`; the digest is the API `digest` or the CLI ID column (lowercase hex, at least 12 characters; a model without one gets no `#<digest>` and cannot be removed). Models without a size (cloud models) are dropped. |
| Hugging Face repos | Hub cache root, first match of `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, `HF_HOME/hub`, `XDG_CACHE_HOME/huggingface/hub`, `~/.cache/huggingface/hub`. Relative env values are ignored. | One per `models--*`, `datasets--*`, `spaces--*` folder. Name `org/name`. Size = regular files in `blobs/` plus real (non-link) files in `snapshots/`. Last used = newest mtime among `refs/**` files and `snapshots/*` folders, falling back to the folder mtime (approximate; shown as a note on the page). |
| Non-standard hub folders | Any other real folder directly in the hub root, for example `hub/mlx-community` | One review row per folder, size = regular files inside, links not followed. Offered only if the root is recognisable as a hub cache (has a `models--*`/`datasets--*`/`spaces--*` folder or `CACHEDIR.TAG`). |
| MLX / GGUF files | Direct children of `~/Library/Application Support/huggingface/models` and `.../gguf_models` | One review row per child, name `models/<child>` or `gguf_models/<child>`, only if it is recognisable model data: a weight file (`.gguf`, `.safetensors`, `.npz`, an `.mlpackage` file or folder, or a `.bin` of at least 50 000 000 bytes, extensions case-insensitive), or a folder whose bounded walk (8 levels, 50 000 entries) finds one. A `config.json` alone is not enough, and a smaller `.bin` is not enough. Other children are not listed and are counted in a note. |

Every row (Ollama, Hugging Face, review rows) has `CleanableItem.selectOnlyByHand = true`: Select visible, the category checkbox and select all skip it; only a click on the row selects it. Deselecting in bulk still works.

Links into a row: the scan walks the hub root, every repo folder (listed or not, including repos hidden as shared-store), every non-standard hub folder and both Application Support folders with `lstat` (no link followed, 8 levels and 50 000 entries per folder) and records the resolved target of every symlink. A row is blocked if a link whose own path is outside that row resolves to the row or inside it: another repo's snapshot link, a link in a non-standard folder such as an old `hf download --local-dir` project kept inside the cache, a link at the hub root, or a link in Application Support. A blocked row is still listed, its second line reads "Linked from <path> · cannot be removed", and removal is refused. A repo's own snapshot links point inside itself and never block it. Limit: links from outside the hub cache and the two Application Support folders (for example a `--local-dir` project in `~/Projects`) are not searched for and cannot be detected; removing the target breaks them. The review sheet says so ("Files linked from outside the cache are not detected."). Example seen on the author's Mac: `hub/mlx-community/Qwen3-VL-4B-Instruct-4bit` links into `hub/models--mlx-community--Qwen3-VL-4B-Instruct-4bit/snapshots/<rev>`, so the repo row is blocked until that link is removed.

Not listed: hidden entries (`.locks`, `.DS_Store`), the hub-level `blobs`, `refs`, `snapshots` names, symlinks, empty folders, repos of size 0.

Why PureMac reads the Hugging Face folders itself and does not use `hf cache ls`: with `hf` 1.11.0 `hf cache ls --format json` returns sizes as strings (`"34.7G"`) and times as `"6 months ago"`, so bytes and dates cannot be recovered. `hf cache ls --help` has `--cache-dir`, `--revisions`, `--filter`, `--format [agent|auto|human|json|quiet]`, `--sort`, `--limit`.

Category notes (shown above the list): Ollama not running or `ollama` missing; `OLLAMA_HOST` not on this Mac; N Hugging Face repos kept in a shared store and not listed; N Application Support items skipped as not model data; the approximate-date note (only when repo rows exist).

`OLLAMA_MODELS` is a server-side setting. PureMac never reads or writes that folder; the server (API delete or `ollama rm`) acts on whatever folder it uses. Environment variables are those of the PureMac process, so a variable exported only in a shell profile is not seen by an app started from Finder.

## How it decides

| Row | Condition | Selectable | Preselected |
|---|---|---|---|
| Ollama model | Listed by the local server/CLI; name passes `isValidOllamaModelName` | by hand only | never |
| Hugging Face repo | Real (non-symlink) `models--*`/`datasets--*`/`spaces--*` folder, size > 0, every link inside resolves into the repo's own `blobs/` | by hand only | never |
| Hugging Face repo with shared store | A link in `blobs/` or `snapshots/` resolves outside the repo's own `blobs/` (for example into `hub/blobs/<xx>/<hash>`) | not listed; counted in a note | - |
| Any row above that a link points into | A symlink found by the walk above resolves to the row or inside it, from outside the row | listed, removal refused | never |
| Non-standard hub folder | Real folder in a recognised hub root, size > 0 | by hand only | never |
| MLX / GGUF entry | Real file or folder directly in an existing, non-symlinked `models` / `gguf_models` folder, size > 0, recognisable model data | by hand only | never |
| Remote `OLLAMA_HOST` | Host is not `localhost`, `127.x.x.x`, `::1` (`0.0.0.0` and empty mean `127.0.0.1`) | no rows | - |
| Implausible hub root | Root resolves to `/`, the home folder or an ancestor, fewer than 3 path components, or a direct personal folder (`Documents`, `Desktop`, `Downloads`, `Library`, ...) | no rows | - |

Scheduled scans never include the category, and Smart Scan includes it only after the user adds it: it is in `CleaningCategory.smartScanExcluded` (set a), so `smartScannable` omits it and the dashboard totals and scheduled cleaning cannot see it. "Add to Smart Scan" in the Overview's "Optional in Smart Scan" list (`AppState.addToSmartScan`; the row is there before, during and after a scan: before one it only saves the choice, during a Smart Scan it joins that scan's end, after one it scans at once in that row, and it stays with what was found and "Remove from Smart Scan") or Settings → Local AI Models → Include in Smart Scan (`LocalAIModels.includeInSmartScanKey` = `settings.cleaning.localAIModels.includeInSmartScan`, default off) adds it to `CleaningCategory.smartScanCategories` (set a2); its row then shows in the Cleanup plan (`AppState.allResults`) as "Reviewed inside the category before removal", outside the junk total. It is also in `CleaningCategory.overviewExcluded` (set b): `AppState.cleanAll` drops its items and the Overview never counts or selects them. Its removal needs the risk sheet (`RemovalRisk.requiresAcknowledgement`, set c). The app's built-in `PureMac scan` command skips it unless `--category "Local AI Models"` is given (scan only; the command never removes).

## How it removes

Only `CleaningEngine.cleanItems` -> `LocalAIModels.remove(_:)`. The review sheet states that removal is permanent and that shared Ollama files stay, and lists risks that must each be ticked before Remove unlocks (`RemovalRisk.risks(for: .localAIModels, items:)`): nothing goes to the Trash; Ollama models go through Ollama, shared files stay, so less space may be freed (shown only with an Ollama row); Hugging Face repos and folders are deleted with all files and must be downloaded in full again; links from outside the cache are not detected (the last two only with a non-Ollama row). "Copy agent prompt" lists every row with its action (`ollama rm <name>` or the folder path).

| Row | Action |
|---|---|
| Ollama model | First the scanned digest is checked against a fresh listing (same API-then-CLI order as the scan; API digest vs `ollama list` ID by prefix, at least 12 characters). Missing digest, tag no longer listed, different digest, or no answer: skipped with a reason, nothing is run. If the API answered that check: `DELETE <host>/api/delete` with `{"model": name, "name": name}` through PureMac's own client, which refuses redirects (the `ollama` CLI follows 307/308 itself, so it is not used while the API is up); a non-200 answer fails the removal and the CLI is not tried. Only if the API was unreachable and `ollama list` answered: `ollama rm <name>` (one argument). Freed space reported = listed size, an upper bound: blobs shared between models stay on disk. |
| Hugging Face repo | If an `hf` binary exists (`/opt/homebrew/bin/hf`, `/usr/local/bin/hf`, `~/.local/bin/hf`) and `hf cache rm --help` exits 0 and mentions `--cache-dir` and `--yes`: `hf cache rm <model\|dataset\|space>/<org>/<name> --cache-dir <root> --yes`. If that is unavailable, fails, or leaves the folder in place: delete that single validated folder with `FileManager.removeItem`, after the whole check runs again (path classification, `inspectHubRepo`, links into the folder). The same check runs before the CLI. |
| Non-standard hub folder, MLX/GGUF entry | Delete that single validated entry with `FileManager.removeItem`. Never the CLI. |

Nothing goes to the Trash: a model in the Trash on the same volume would keep the space in use. Blob and manifest files under the Ollama models folder are never touched by hand. `hf cache prune` and `ollama pull/push` are never run.

## Safety invariants

1. Models are user data and never preselected, scheduled or bulk-cleaned; Smart Scan lists them only once the user added them, and even then the Overview never counts, selects or cleans them. `CleaningCategory.smartScannable`, `smartScanCategories`, `AppState.allResults`, `AppState.cleanAll`, `AppState.runScheduledScan` enforce it. Tests: `testLocalAIModelsAreScannableButNeverPartOfSmartScanOrSchedules`, `SmartScanOptInTests.testWorktreesAndModelsJoinOnlyAManualSmartScanAndOnlyWhenAdded`, `testAddedCategoriesShowInThePlanButNeverInTotalsOrSelection`, `testBulkCleaningResultsExcludeLocalAIModelsEvenWhenSelected`, `testScanEngineReturnsUnselectedRowsAndNotesForTheCategory`.
2. The generic allow-list is not widened. `CleaningEngine.cleanItems` routes `.localAIModels` to `LocalAIModels.remove` before any generic check; `isSafeToDelete(item:resolvedPath:)` returns false for the category; `cleanWithAdminPrivileges` refuses it. Test: `testLocalAIModelRowsNeverReachTheGenericDeleteOrAdminPass`.
3. Ollama removal is one of two calls: `DELETE /api/delete` when the API answered the digest check, `ollama rm <name>` (nothing else) when only `ollama list` answered. Names must match `[A-Za-z0-9._-:/@+]`, be at most 255 bytes and not start with `-` (`LocalAIModelsSupport.isValidOllamaModelName`). Tests: `testOllamaRemovalUsesOllamaRmOnlyWhenTheAPIIsUnreachable`, `testOllamaRemovalPrefersTheRedirectRefusingAPIDeleteWhenTheAPIAnswered`, `testOllamaRemovalDoesNotFallBackToTheCLIWhenTheAPIDeleteIsRedirectedOrRefused`, `testOllamaRemovalRefusesUnsafeNamesAndRemoteHosts`.
4. Only loopback `OLLAMA_HOST` is used (`LocalAIModelsSupport.ollamaEndpoint` -> `isLoopback`); no request or command is made for a remote host. Test: `testOllamaScanReportsRemoteHostsInsteadOfTalkingToThem`.
5. A removable path is a direct child of a known root, normalised (no `.`, `..`, empty or trailing components, no NUL), not a symlink (`lstat`), and `realpath(path) == root/name` (`LocalAIModels.classify`). Known roots are the resolved hub root and the two fixed Application Support folders; the latter must also resolve to themselves (no link anywhere in the chain). Tests: `testRemovalRefusesEverythingThatIsNotADirectChildOfAKnownModelRoot`, `testRemovalRefusesASymlinkedRepoFolderAndLeavesTheTargetUntouched`, `testApplicationSupportEntriesAreRemovedButASymlinkedRootIsRefused`, `testHuggingFaceScanSkipsSymlinkedRepoFolders`.
6. Validation runs again immediately before `removeItem`, after the CLI attempt, and it is the full check, not only the path: `LocalAIModels.removeHubEntry` calls `classify` and `removalBlock` (repo inspection plus links into the folder) before the CLI and again before the fallback delete. Test: `testFallbackAfterAFailedHFCLIRunsTheFullInspectionAgain` (fake `hf` fails after adding an outgoing link, or an incoming link).
7. Links inside a removed folder are unlinked, never followed; sizes never count links. `LocalAIModelsSupport.treeBytes`, `inspectHubRepo`. Test: `testNonStandardFolderRemovalDeletesOneFolderAndNeverFollowsLinksInside`.
8. A repo whose files sit behind links to a shared store is not listed and is refused if forged: deleting the folder would free nothing. `LocalAIModelsSupport.inspectHubRepo` (`linksOutsideRepo`). Tests: `testHuggingFaceScanReportsReposWhoseBlobsLiveInASharedStoreInsteadOfListingThem`, `testRemovalRefusesAReposWhoseFilesLiveInASharedStore`.
9. The hub root must be plausible and, for non-standard folders, recognisable as a hub cache, so a stray `HF_HOME` cannot make arbitrary folders removable. `LocalAIModelsSupport.isPlausibleHubRoot`, `LocalAIModels.isRecognisedHub`. Tests: `testHuggingFaceScanRefusesImplausibleRootsAndRespectsEnvironmentPrecedence`, `testHuggingFaceScanDoesNotOfferFoldersOfAnUnrecognisedCacheRoot`.
10. The `hf` CLI is driven only after its help output documents the flags used. Test: `testAnHFCLIWithoutTheDocumentedFlagsIsNeverDrivenForRemoval`; fallback: `testRemovalFallsBackToTheValidatedFolderWhenTheHFCLIFailsOrDoesNothing`.
11. Every external call has a timeout (`LocalAIModelsContext.listTimeout` 15 s, `removeTimeout` 120 s, API listing request 5 s) and a timed-out API call does not trigger a second wait on the CLI. Tests: `testOllamaScanGivesUpOnAHangingCLI`, `testOllamaScanDoesNotWaitTwiceWhenTheServerTimesOut`, `testOllamaRemovalReportsFailuresAndTimeouts`.
12. A row that a symlink points into is never removed, and the link index is rebuilt right before removal. The index covers the hub root, all repo folders (also unlisted ones), non-standard hub folders and Application Support; links from elsewhere on disk cannot be found (see the limit under "What it finds"). `LocalAIModelsSupport.collectSymlinks`, `linkPointingInto`; `LocalAIModels.symlinkIndex`, `removalBlock`. Tests: `testRowsThatAreLinkTargetsAreBlockedAtScanAndRemovalAndNameTheLink`, `testALinkCreatedAfterTheScanBlocksRemovalAndLinksAtTheHubRootAndInApplicationSupportCount`, `testARepoThatLinksIntoAnotherRepoBlocksTheTargetEvenWhenTheLinkingRepoIsNotListed`, `testAProjectFolderInsideTheCacheThatLinksToCachedBlobsBlocksTheRepo`, `testCollectSymlinksIsBoundedAndDoesNotFollowLinks`.
13. Bulk selection never selects a Local AI Models row. `CleanableItem.selectOnlyByHand`, honoured through the single rule `CleanableItem.isExcludedFromBulkSelection` by `AppState.setSelection`, `AppState.selectAllInCategory` (and so `categoryBinding`) and the Select visible button in `CategoryDetailView`. Tests: `CategoryRulesTests.testSelectAllInCategorySkipsThemAndKeepsTheControls`, `testSelectVisibleAndSetSelectionSkipThem`, `testBulkSelectionPathsNeverSelectLocalAIModelRowsButDeselectAndClickStillWork`, `testOllamaScanRecordsTheDigestInTheRowPathAndKeepsRowsOutOfBulkSelection`, and the `allSatisfy(\.selectOnlyByHand)` check in `testHuggingFaceScanListsReposWithBlobSizeAndApproximateLastUse`.
14. HTTP to the Ollama server never follows a redirect: `LocalAIModelsContext.liveFetch` uses a session delegate (`RefuseRedirects`) that answers every redirect with nil, so the 3xx is returned as the response and treated as a failure; the delete goes through this client whenever the API answered (invariant 3). Tests: `testLiveFetchDoesNotFollowRedirects`, `testRedirectDelegateRefusesEveryRedirect`.
15. Ollama removal is by name, so the scanned digest must still match: `LocalAIModels.confirmOllamaDigest`. Tests: `testOllamaRemovalSkipsAModelWhoseDigestChangedSinceTheScan`, `testOllamaRemovalSkipsWhenTheDigestIsMissingTheModelIsGoneOrTheServerIsSilent`, `testOllamaRemovalConfirmsThroughTheListIDColumnWhenOnlyTheCLIAnswers`, `testOllamaDigestMatching`.
16. Application Support entries are listed only if they contain a model-weight file (`.gguf`, `.safetensors`, `.npz`, `.mlpackage`, `.bin` of at least 50 000 000 bytes); `config.json` alone does not qualify. `LocalAIModelsSupport.looksLikeModelData`. Tests: `testApplicationSupportOffersOnlyRecognisableModelData`, `testModelDataRecognitionThresholds`.
17. User exclusions (`CleanupExclusions`) still apply; they are checked before the category route.
18. A Hugging Face entry inside iCloud Drive or a file provider (`HF_HOME` or `HF_HUB_CACHE` pointed there) is refused, before the `hf` CLI and before the fallback delete. `LocalAIModels.removalBlock` (`ProviderPaths.isProviderOwned`). Test: `testRemovalRefusesACacheInCloudProviderStorage`.

## Failure modes and logs

Logger entries go to the unified log (`log stream --predicate 'subsystem == "com.puremac.app"'`); the app keeps the last 1000 in memory but no screen shows them.

| Symptom | Cause | Where to look |
|---|---|---|
| Page says Ollama is not running or `ollama` was not found | Server down, no binary at the three lookup paths, or `OLLAMA_HOST` unparsable | `Local AI Models: /api/tags failed`, `Local AI Models: ollama list exited`, `Local AI Models: OLLAMA_HOST could not be parsed` |
| Row refused: "in iCloud Drive or another cloud-synced folder" | Hugging Face cache under `ProviderPaths.deniedRoots` or a `com~apple~` path | row error `Skipped <name>: it is in iCloud Drive or another cloud-synced folder` |
| Page says `OLLAMA_HOST` points to another machine | Non-loopback host in PureMac's environment | `Local AI Models: OLLAMA_HOST is not a loopback address` |
| Ollama list takes ~5 s then shows nothing | API timed out (`/api/tags timed out`) | `Local AI Models: /api/tags timed out` |
| Ollama removal error in the cleanup alert | API delete answered non-200 (including a redirect), `ollama rm` exited non-zero or timed out, or the server stopped | `DELETE /api/delete <name> answered <status>`, `DELETE /api/delete <name> failed`, `ollama rm <name> exited <status>`, `ollama rm <name> timed out` |
| Fewer Hugging Face repos than `hf cache ls` shows | Repos keep files in a shared store, or the cache is under a different `HF_HOME` than the one PureMac sees | the "shared store" note on the page; compare `HF_HUB_CACHE`/`HF_HOME` of the Finder-launched app |
| "Refusing to remove ..." in the alert | Path failed validation (symlink, not a direct child, root changed since the scan) | `Refusing to remove <path>`, `Aborting removal: <path> changed between validation and delete` |
| "Skipped <repo>: its files live in a shared store" | Forged or stale row for a shared-store repo | `Skipped <name>: its files live in a shared store` |
| Row says "Linked from <path> · cannot be removed", or the alert says "<path> links into it" | A symlink in the hub root, a non-standard hub folder or Application Support points into the row | `Skipped <folder>: <path> links into it, so removing it would break that link` |
| "Skipped <model>: ..." for an Ollama model | Scanned digest missing, tag re-pulled or removed since the scan, or Ollama did not answer | `Skipped <name>: no digest was recorded at scan time`, `Skipped <name>: Ollama no longer lists it`, `Skipped <name>: the model changed since the scan (different digest)`, `Skipped <name>: Ollama did not answer` |
| Application Support item missing from the list | Not recognisable model data | the "not listed because they do not look like model data" note |
| Repo removed but `hf` is not used | No `hf` found, or its help lacks `--cache-dir`/`--yes` | `hf cache rm --help failed`, `hf cache rm <target> did not remove the repo; deleting the validated folder instead` |
| Error `Skipped Docker/OrbStack disk state: <path>` | A forged row points at Docker's VM disk or a parent of it; the shared deny list refuses before any model logic | `CleaningEngine.isDockerDiskState`; log `Refusing to delete Docker/OrbStack disk state: <path>` |
| Freed space smaller than the listed Ollama size | Blobs shared with other models stay | review sheet text; `Removed Ollama model <name> (listed size N bytes)` |

## Testing

```
xcodegen generate
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/local-ai-dd" CODE_SIGNING_ALLOWED=NO -only-testing:PureMacTests/LocalAIModelsTests
```

Fixtures live under `$TMPDIR/PureMac-LocalAI-<uuid>` and are removed in `tearDown`. `ollama` and `hf` are shell scripts in that folder, injected through `LocalAIModelsContext.ollamaExecutableCandidates` / `hfExecutableCandidates`; each appends its arguments to `$FAKE_LOG`, and the fake `hf` only deletes inside the sandbox. HTTP is a stub closure (`LocalAIModelsContext.fetch`), so no socket is opened. The real `ollama`, `hf` and servers are never started by tests.

Manual run against a fake home (build first, then):

```
CFFIXED_USER_HOME=<fixture-home> <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac
```

Put `.cache/huggingface/hub/models--org--name/{blobs,snapshots,refs}` and `Library/Application Support/huggingface/models/<x>` in the fixture home. Ollama rows then depend on whether a server answers on `127.0.0.1:11434`: start a stub server on another port and set `OLLAMA_HOST=127.0.0.1:<port>` to avoid touching a real one. Do not run Remove against a real home.

## Related

- [Apple controls and storage research](APPLE-FEATURES.md) (model storage that PureMac shows but does not promise to reclaim)
- `PureMac/Models/Models.swift` (`CleaningCategory.localAIModels`, `smartScanExcluded`, `overviewExcluded`, `CleanableItem.ollamaModelPathPrefix`), `PureMac/Logic/Utilities/RemovalRisk.swift` (`acknowledgedCategories`, risks)
- `PureMac/Services/ScanEngine.swift` (`scanLocalAIModels`), `PureMac/Services/CleaningEngine.swift` (`cleanItems`)
- `PureMac/Views/CategoryDetailView.swift` (notes banner, review text)
- `cli/Sources/puremac/Core/Safety.swift` (the standalone CLI keeps `~/.ollama` protected except `logs`; it does not remove models)
