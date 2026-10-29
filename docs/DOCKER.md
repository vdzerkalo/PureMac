# Docker Cache

> Docker Cache category: file caches of Docker Desktop and OrbStack plus five virtual rows, four `docker ... prune` commands and one `docker volume rm <recorded names>`. Code: `PureMac/Logic/Utilities/DockerSupport.swift` (`PruneAction`, `pruneEstimates`, `danglingEstimate`, `volumeEstimate`, `isProtectedDiskPath`), `PureMac/Services/ScanEngine.swift` (`scanDockerCache`), `PureMac/Services/CleaningEngine.swift` (`pruneDocker`, `removeDockerVolumes`, `isSafeToDelete`), `PureMac/ViewModels/AppState.swift` (`cleanAll`), `PureMac/Logic/Utilities/RemovalRisk.swift`. Tests: `PureMacTests/DockerSupportTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Docker.raw and returning space to macOS](#dockerraw-and-returning-space-to-macos)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Related](#related)

## What it finds

**File rows** (plain directories, removed by unlinking; selected by default when size > 0). Each exists only if the path exists and is non-empty:

- `~/Library/Containers/com.docker.docker/Data/{cache,log,tmp}`
- `~/Library/Group Containers/group.com.docker/Caches`
- `~/.docker/cli-plugins/.cache`, `~/.docker/buildx/cache`
- `~/.orbstack/log`, `~/Library/Caches/dev.kdrag0n.MacVirt`, `~/Library/Logs/OrbStack`

**Virtual rows** (path `docker-prune:<action>`, no file): shown only when a `docker` binary is found and the daemon answers `docker system df` within 10 s.

Binary search order, first executable wins (`DockerSupport.candidateBinaryPaths`):

1. `/usr/local/bin/docker`
2. `/opt/homebrew/bin/docker`
3. `~/.docker/bin/docker` (Docker Desktop "user" install)
4. `~/.orbstack/bin/docker`
5. `/Applications/Docker.app/Contents/Resources/bin/docker`

`DOCKER_HOST` and the current docker context are inherited from the app's environment (the child process gets `ProcessInfo.processInfo.environment`), so the CLI talks to whichever daemon that selects.

**Docker.raw** (`~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`) is never a row. Its allocated size (`totalFileAllocatedSize`, not the apparent length) is shown in the category note when > 0.

## How it decides

Display order is the `PruneAction` declaration order. "Estimate" is what the row shows; the clean reports what Docker says it actually freed.

| Row (exact label in the app) | Command | Shown when | Size shown | Preselected |
|---|---|---|---|---|
| Docker build cache | `docker builder prune -a -f` | df `Build Cache` Reclaimable > 0 | df Reclaimable | no |
| Stopped Docker containers | `docker container prune -f` | df `Containers` Reclaimable > 0 | df Reclaimable | no |
| Dangling Docker images (untagged leftovers) | `docker image prune -f` | `docker images --filter dangling=true` lists at least one image no container uses | lower bound, see below | no |
| Dangling Docker images (untagged leftovers, size not estimated) | `docker image prune -f` | same, but no reliable size | `0` (means not estimated, not "frees nothing") | no |
| All unused Docker images (pulled or rebuilt when needed) | `docker image prune -a -f` | df `Images` Reclaimable minus dangling estimate > 0 | df Reclaimable minus dangling estimate | no |
| Unused Docker volumes (may contain data such as databases) | `docker volume rm <name> <name> …` (the exact names recorded at scan time, no `-f`) | `docker volume ls -q --filter dangling=true` lists at least one volume no container references | sum of those volumes' own sizes (`docker system df -v` Volumes `Size`) | no, and skipped by "Select visible" and the category checkbox (`requiresExplicitSelection`); only a click on the row selects it |
| Unused Docker volumes (…, size not estimated) | same | same, but no size (`df -v` failed, or every size is `N/A`/0) | `0` (not estimated) | same |

The file rows are selected by default; every virtual row is not.

**Where the rows can be removed.** The category screen only: its review sheet lists the risks of exactly the selected rows and each must be ticked (`RemovalRisk.requiresAcknowledgement(.dockerCache)`). The Overview never counts, selects or cleans Docker Cache: `AppState.cleanAll` (manual, scheduled, and the Full Disk Access retry) drops every item of a category that requires acknowledgement; `totalSelectedSize` and the Clean button exclude it; its Overview checkbox is disabled and the row reads "Reviewed inside the category before removal". A scheduled run scans first and returns every virtual row unselected, and would skip them anyway.

### Estimate sources and why they are conservative

- **df rows** (`docker system df --format '{{json .}}'`, `DockerSupport.parseSystemDF`): the `Reclaimable` column, percentage ignored. Docker rounds these values to 4 significant digits.
- **Dangling images** (`DockerSupport.danglingEstimate`). The image IDs come from `docker images --filter dangling=true --no-trunc --format '{{.ID}}'`, the same filter `image prune -f` applies. The bytes come from `docker system df -v --format '{{json .}}'` (Images array), matched by ID:
  - an image's `UniqueSize` counts only layers no other image uses, so deleting the image frees at least that. `Size` is not used because it includes shared layers;
  - images with `Containers` > 0 (a stopped container counts) are skipped: prune keeps them;
  - layers shared only between dangling images, or with an image deleted in the same run, are not counted. The figure can be too low, never too high (apart from Docker's rounding);
  - df's own `<none>:<none>` rows are not used to find dangling images. On the containerd image store (Docker Desktop 29, seen on a real install) df -v lists digest-only references such as `repo@sha256:...` as `<none>:<none>`, and `image prune -f` keeps those.
  - If `df -v` fails or times out, the row is still offered (the filter found images) with size 0 and the "size not estimated" label. If the filter command fails, no dangling row appears.
- **Both image rows selected.** The `-a` command also removes dangling images, so its df figure already contains them. To keep the sum honest, the `-a` row shows df Reclaimable minus the dangling estimate (never below 0; the row is hidden at 0). Selected alone, the `-a` row therefore under-promises by the dangling estimate; selected together the sum equals df's figure. If the dangling size is unknown the `-a` row shows df's figure unchanged and the dangling row shows 0, so nothing is counted twice.
- **Volumes** (`DockerSupport.volumeEstimate`). The names come from `docker volume ls -q --filter dangling=true` (volumes no container references, running or stopped: the set `volume prune -a` would take). Sizes come from the same `docker system df -v` call (run once for images and volumes, only when something was found). A volume's size is its own data and shares nothing, so the sum is exact apart from Docker's rounding. A volume df says a container uses is dropped; a volume without a size counts 0. Names must match `[A-Za-z0-9][A-Za-z0-9_.-]*` (`isValidVolumeName`); others are dropped, so a name cannot become an option or a path. The row records the names and bytes in its path: `docker-prune:volumes:<name>=<bytes>,…`.
- **No `docker system prune`, no `docker volume prune`.** `system prune` would remove things the rows do not list (networks) and hide per-row choice. `volume prune -a` would also erase volumes that only become unused when the container prune in the same run removes their stopped container, up to gigabytes the user never saw in the list.

## How it removes

Each selected virtual row runs through `BrewProcessRunner` (stdout and stderr drained, timeout enforced, process terminated then SIGKILLed on timeout). No file is unlinked for these rows and nothing goes to the Trash. Prune and `volume rm` runs use `keepOutputTail`: only the last 1 MB of each pipe is kept and the 4 MB output cap (which stops Homebrew runs) never kills them, because a long `image prune -a` or `builder prune` lists every deleted object and prints its summary last. The scan lookups keep the cap (a cut-off JSON would not parse).

Run order, not display order (`PruneAction.cleanOrder`, applied by `DockerSupport.orderedForCleaning` at the start of `CleaningEngine.cleanItems`):

1. `docker volume rm <recorded names>`: FIRST, before the container prune. A stopped container holds its volumes; removing it would make them unused after the user reviewed a list without them.
2. `docker container prune -f`: releases images held by stopped containers, so the image prunes find more. Estimates only under-promise because of this.
3. `docker image prune -f`
4. `docker image prune -a -f`: runs after the dangling prune, so it reports only what is left.
5. `docker builder prune -a -f`: independent and can run for minutes, so last.

Non-Docker items keep their position; Docker rows only swap among the slots Docker rows already had.

**Volumes** (`CleaningEngine.removeDockerVolumes`):

1. Re-check right before acting: `docker volume ls -q --filter dangling=true`; the targets are the recorded names that are still unused. A volume that vanished, or that a container references now, is skipped silently (logged at info as `docker volume rm: N recorded volume(s) no longer exist or are in use now, skipped`). If nothing is left, no removal runs and the row counts as cleaned.
2. `docker volume rm <targets>` without `-f`: the daemon itself refuses a volume that is in use, so a race after step 1 cannot erase one. Docker prints each removed name on stdout and one error line per failed volume on stderr. Failures are reported per volume (`docker volume rm: remove <name>: volume is in use - [...]`), the other volumes are still removed, and a row with a failure is not marked cleaned. A `no such volume` line is silent.
3. Freed space is the scan-time size of each volume Docker printed as removed (`volume rm` prints no byte count).

**Freed space for prunes.** `DockerSupport.parseReclaimedSpace` reads the last `Total reclaimed space: N` line (container, image prune) or `Total:\tN` line (builder prune) from each command. Every command prints only what it removed itself, so the totals add up without overlap; a command with no summary line counts 0.

**What is removed and what never is**

| Command | Removes | Never removes |
|---|---|---|
| `docker volume rm <names>` | exactly the recorded volumes that are still unused: **data is erased** | any volume not recorded at scan time (including ones a container prune would free); any volume a container references now |
| `docker container prune -f` | all stopped containers and their writable layers | running containers |
| `docker image prune -f` | images with no tag and no digest reference, not used by any container | tagged images; images any container (even stopped) uses |
| `docker image prune -a -f` | every image no container uses, tagged or not (includes dangling) | images any container uses |
| `docker builder prune -a -f` | all build cache not in use | cache of a build running right now |

Per Docker's CLI definitions; PureMac relies on the daemon for these rules and does not re-implement them.

**Review sheet.** `RemovalRisk.risks(for: .dockerCache, items:)` lists one risk per selected kind of row, all of which must be ticked before Remove unlocks: always "Nothing goes to the Trash"; then, only when selected, build cache (next build is slower), stopped containers (deleted with their files), images (`-a`: all unused images, tagged or not; locally built ones can only be rebuilt) or, if `-a` is not selected, dangling images (rebuild from source), and volumes ("The volumes named in the command are erased with their data"). "Copy agent prompt" lists every found row with its exact command, including the volume names.

## Docker.raw and returning space to macOS

Checked 2026-10-29 by fetching the pages below (the fetch tool returned condensed text; quotes are short fragments).

**Docker Desktop**, [FAQs for Docker Desktop for Mac](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/):

- Containers and images live in "a single, large disk image file" on the Mac. The file is `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`; the FAQ's `ls -klsh Docker.raw` example shows actual size next to maximum size, and warns that other tools may report the maximum size. The page does not use the words "sparse file" or TRIM.
- After `docker system prune`: "It might take a few minutes to reclaim space on the host."
- "Space is freed only when images are deleted", not when files are deleted inside running containers.
- On-demand reclaim: `docker run --privileged --pid=host docker/desktop-reclaim-space`.
- Lowering the maximum **Disk image size** (Settings > Resources > Advanced) deletes the disk image: all containers and images are lost.

[Troubleshoot](https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/): the menu item is **Clean up data** (not "Clean / Purge data"); "A disk image reset destroys all Docker containers and images local to the machine, preserving all settings." The page does not mention Docker.raw, TRIM or `desktop-reclaim-space`. The [Settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/) page lists a "Disk usage limit" and "Disk image location" and does not mention how freed space returns to macOS.

What the app does with this: the category note (shown only when Docker.raw exists) says how much the file uses on disk, that Docker says freed space can take a few minutes to return to macOS, and prints the `docker/desktop-reclaim-space` command for the user to run if it does not. PureMac never runs that command, never opens Troubleshoot or Settings, never resets or resizes the disk image, and never touches Docker.raw.

**OrbStack**, [FAQ: "Why is there an 8 TB data file?"](https://docs.orbstack.dev/faq): `data.img` (`~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img`) is a sparse virtual disk image with an apparent size (8 TB) and a size on disk; it "automatically shrinks when you delete data". Real usage: `du -h` on the file or "size on disk" in Finder. The page says nothing about `docker prune` or how long shrinking takes. PureMac scans no OrbStack disk image and shows no OrbStack-specific note.

## Safety invariants

1. Only fixed argument lists run, plus `docker volume rm` on validated recorded names. Never `system prune`, never `volume prune`, never `-f` on `volume rm`: `DockerSupport.PruneAction.arguments`, `DockerSupport.arguments(forPath:)`, `CleaningEngine.removeDockerVolumes`. Tests: `testPruneActionArgumentsMatchWhatDfCountsAsReclaimable`, `testVolumesRowPathRoundTripsAndDropsInvalidNames`, `testVolumeNamesAreValidatedSoTheyCannotBecomeOptionsOrPaths`.
2. A volume the user did not see is never removed, even when a container prune in the same run frees it: volumes run first and only by recorded name, re-checked as unused right before: `PruneAction.cleanOrder`, `removeDockerVolumes`. Tests: `testVolumeRemovalNeverTouchesVolumesFreedByTheContainerPrune`, `testRecordedVolumeThatVanishedOrBecameUsedIsSkippedSilently`, `testVolumeInUseAfterTheRecheckIsReportedPerVolumeAndTheRestStillGo`, `testNothingLeftToRemoveRunsNoRemoval`.
3. Virtual rows are never preselected and volumes need an explicit click: `ScanEngine.swift` → `scanDockerCache` (`isSelected: false`), `PruneAction.requiresExplicitSelection`. Tests: `testOnlyVolumesRequireExplicitSelection`, `testPruneRowsAreActionItems`.
4. Docker rows are removed only after the per-risk review: `AppState.swift` → `cleanAll`, `retryCleanItems`, `totalSelectedSize`, `categoryBinding` skip every category with `RemovalRisk.requiresAcknowledgement`; the review lives in `CategoryDetailView` (`cleanCategory`). Test: `DockerOverviewTests.testCleanAllNeverRunsDockerPrunesWhateverIsSelected` (fake CLI log must not exist).
5. Virtual rows never reach the unlink path: `CleaningEngine.swift` → `cleanItems` routes `dockerPruneAction` before any file deletion; `CleanableItem.isActionItem` hides reveal-in-Finder.
6. Docker Desktop and OrbStack VM disks are never unlinked, by the user pass or the admin pass: `DockerSupport.isProtectedDiskPath` is evaluated before the allow-list in `CleaningEngine.isSafeToDelete(item:…)` (every category) and `isSafeToDelete(resolvedPath:)`, for the literal and the resolved path, case-insensitively. Denied: `Library/Containers/com.docker.docker` (the container, its `Data`, and `Data/vms`), `Library/Group Containers/group.com.docker` except `Caches`, `Library/Group Containers/<team>.dev.orbstack` and its `data`, `.orbstack` and `.orbstack/data`, `.docker/desktop`. The allow-list entry for the whole `com.docker.docker` container was replaced by `Data/cache`, `Data/log`, `Data/tmp`. The broad `~/Library/Containers` and `~/Library/Group Containers` roots are unchanged for other categories; the deny rule is what keeps Docker's disks out. Consequence: an app uninstall that goes through the admin pass cannot escalate to delete Docker's container folder. Tests: `testDockerAndOrbStackDisksAreRefusedInUserAndAdminPass`, `testDockerCacheFoldersStayCleanable`, `testCleanItemsLeavesDockerRawOnDisk`.
7. A size is never larger than what the command frees: `DockerSupport.danglingEstimate` (unique size, skips in-use images, dangling IDs from the prune filter), `DockerSupport.volumeEstimate` (the recorded volumes' own sizes) and `pruneEstimates` (disjoint image rows, never negative). Tests: `testDanglingEstimateCountsUniqueSizeOfUnusedDanglingImagesOnly`, `testPruneEstimatesMakeTheTwoImageRowsDisjoint`, `testImagesRowNeverGoesNegative`, `testVolumeEstimateUsesOnlyTheRecordedUnusedVolumesAndTheirOwnSizes`.
8. An unknown size is shown as 0 with a label, not guessed: `pruneEstimates` (`sizeKnown`), `ScanEngine.dockerPruneItemName`. Tests: `testDanglingRowWithoutAFigureIsLabelledUnknownAndKeepsTheImagesRow`, `testDanglingEstimateHasNoSizeWhenVerboseDFIsUnavailable`.
9. Selected rows run in a fixed order and freed bytes add up from per-command output: `PruneAction.cleanOrder`, `DockerSupport.orderedForCleaning`. Tests: `testCleanOrderRunsVolumesBeforeContainersThenDanglingThenAllImagesThenBuildCache`, `testOrderedForCleaningOnlyMovesDockerRowsWithinTheirOwnSlots`, `testCleanRunsSelectedPrunesInOrderAndSumsFreedSpaceWithoutOverlap`.
10. The user acknowledges the risks of exactly the selected rows: `RemovalRisk.risks`. Tests: `testRisksMatchTheSelectedRowsExactly`, `testRiskTextsNameWhatTheCommandRemoves`.
11. A cancelled or failed command never marks a row cleaned, and a running daemon's error is never shown as "Docker isn't running": `CleaningEngine.runDocker` (cancel → error), `dockerFailure` (stderr logged first), `DockerSupport.isDaemonUnavailable` (only `Cannot connect to the Docker daemon`, `Is the docker daemon running`, `dial unix`). Tests: `testCancelledPruneIsAnErrorNotACleanedRow`, `testRunningDaemonErrorKeepsDockerErrorTextAndIsNotMappedToNotRunning`, `testRealConnectionErrorStillReadsAsDockerNotRunning`, `testRunningDaemonErrorsAreNotReportedAsDockerNotRunning`.
12. A long prune is not killed by the output cap: `BrewProcessRunner.run(keepOutputTail:)` (Docker prune and `volume rm` only; Homebrew behaviour unchanged). Tests: `testLongPruneOutputStillYieldsTheSummary`, `testDefaultRunnerStillFailsPastTheOutputCapAndTailModeDoesNot`.
13. Every docker call has a timeout (10 s `df`, 30 s each lookup and the volume re-check, 900 s prune or `volume rm`), so a wedged daemon cannot hang a scan or clean: `ScanEngine.swift` → `dockerDiskUsage`, `dockerLookup`; `DockerSupport.pruneTimeout`, `danglingLookupTimeout`.
14. Tests never run a real docker: `CleaningEngine(homeDirectory:dockerBinaryPath:)` and `AppState(cleaningEngine:)` take a fake CLI script (`makeFakeDockerCLI`); the fake answers `volume prune` with "unexpected" so a call to it would also fail the log assertions; pure parsing is tested on captured output.

## Failure modes and logs

Logs go through `Logger.shared.log(...)` (Console.app, subsystem = the app bundle id, category `general`; also the in-app log). Run errors use Docker wording (`DockerSupport.describe`): `timed out after Ns`, `printed more output than PureMac can read`, otherwise the system error text.

| Symptom | Cause | Where to look |
|---|---|---|
| No virtual rows, no note about Docker | No docker binary at the five paths; daemon not running; `docker system df` exited non-zero (silent, no log); more than 10 s | Run `docker system df` yourself. Timeout or launch error logs `docker system df failed: timed out after 10s` (warning) |
| No dangling row although `docker images -f dangling=true` lists images | The filter command failed or timed out (30 s) | Log `docker images --filter dangling=true failed: <error>` (warning); a non-zero exit is silent |
| No volumes row although unused volumes exist | `docker volume ls --filter dangling=true` failed or timed out (30 s) | Log `docker volume ls --filter dangling=true failed: <error>` (warning); a non-zero exit is silent |
| A row says "size not estimated" | `docker system df -v` failed, timed out (30 s), returned unparseable JSON, or the figure is 0 (all image layers shared; volume sizes `N/A`) | Log `docker system df -v failed: <error>` (warning) for failures; the other cases log nothing |
| Clean error `Docker CLI not found — install Docker Desktop or OrbStack` | Binary vanished between scan and clean | `DockerSupport.candidateBinaryPaths` |
| Clean error `Docker isn't running — start Docker Desktop or OrbStack, then clean again` | Non-zero exit and stderr contains `Cannot connect to the Docker daemon`, `Is the docker daemon running` or `dial unix` | Log `<command> exited N: <stderr>` (error) is written first |
| Clean error `<command> failed (exit N)` | Non-zero exit for any other reason, for example `Error response from daemon: a prune operation is already running` | Log `<command> exited N: <stderr>` (error) |
| Clean error `<command> did not finish in time — check Docker Desktop or OrbStack, then clean again` | Ran past the timeout (900 s; 30 s for `docker volume ls`); process terminated, then SIGKILLed | Log `<command> timed out after Ns` (error) |
| Clean error `<command> was cancelled before it finished — some objects may already be removed; scan again` | The clean task was cancelled mid-command; the row stays in the list | Log `<command> was cancelled` (warning) |
| Clean error `<command> printed more output than PureMac can read — run it in Terminal to see the result` | Only the `docker volume ls` re-check can hit the output cap (prunes keep the tail) | Log `<command> printed more output than PureMac can read` (error) |
| Clean error `Couldn't run <command>: <error>` | The binary could not be launched | Log `<command> failed to launch: <error>` (error) |
| Clean error `docker volume rm: remove <name>: volume is in use - [...]` | The volume became used between the re-check and the removal; the daemon refused it. Other volumes of the row were still removed | Log line with the same text (warning) |
| Clean error `No unused volumes were recorded for this row — scan again` | A volumes row without valid names (tampered or empty path) | `DockerSupport.volumeEntries(forPath:)` |
| Volumes row cleaned, fewer volumes removed than listed | Recorded volumes that vanished or became used were skipped on purpose | Log `docker volume rm: N recorded volume(s) no longer exist or are in use now, skipped` (info), then `docker volume rm removed N of M volume(s), B bytes (scan-time sizes)` (info) |
| Row cleaned but freed bytes show 0 | Prune printed no `Total reclaimed space:` / `Total:` line, or nothing was removed | Log `<command> reclaimed N bytes` (info) |
| Error `Skipped symlink or unsafe path: <path> -> <resolved>` for a Docker or OrbStack path | The path is a protected VM disk or container (`isProtectedDiskPath`) or outside the allow-list | Log `Refusing to delete Docker/OrbStack disk state: <path>` (warning); in the admin pass `Refusing admin escalation for unsafe path: <path>` |
| Docker.raw does not shrink after a clean | See [above](#dockerraw-and-returning-space-to-macos): up to a few minutes; images must actually have been deleted | `du -h` or `ls -klsh` on Docker.raw |

`<command>` is the exact command line for prunes (for example `docker image prune -f`) and `docker volume rm` / `docker volume ls` for volumes. If one command of several fails, the others still run (each row reports its own error); the row that failed stays in the list.

## Testing

Unit tests (fake output only, no docker daemon):

```
xcodegen generate
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' -derivedDataPath "$TMPDIR/docker-dd" CODE_SIGNING_ALLOWED=NO -only-testing:PureMacTests/DockerSupportTests -only-testing:PureMacTests/RemovalRiskTests
```

The clean-order and freed-space tests write a fake `docker` shell script into a temp directory, which logs its arguments and prints canned prune summaries.

Manual check against an isolated daemon, so the daemon that holds real data is never involved (described here, not automated):

1. Start a throwaway daemon: `docker run --privileged -d --name puremac-dind -e DOCKER_TLS_CERTDIR= -p 127.0.0.1:23750:2375 docker:dind`.
2. Record the host state first, with `DOCKER_HOST` unset: `docker images -a --no-trunc -q | sort > host-before.txt`, likewise `docker ps -a -q` and `docker volume ls -q`.
3. Point the CLI at the throwaway daemon: `export DOCKER_HOST=tcp://127.0.0.1:23750`. Create fixtures there: pull a small image, build twice under one tag (the first build becomes dangling), create a stopped container, a named volume, some build cache.
4. Start PureMac with the same variable so its docker calls inherit it: `DOCKER_HOST=tcp://127.0.0.1:23750 <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac`. Scan Docker Cache, compare each row with `docker system df -v` on the throwaway daemon, run the rows, compare "Total reclaimed space" with the sizes shown.
5. Unset `DOCKER_HOST` and re-record the host lists. The before and after files must be identical (`diff`).
6. The throwaway container `puremac-dind` itself lives on the host daemon. Remove it by hand when done, after checking with `docker ps -a --filter name=puremac-dind` that the name matches only that container.

## Related

- [`docs/llms.txt`](llms.txt) (removal behaviour), [`README.md`](../README.md) (System Cleaner list)
- `PureMac/Services/ApplicationUpdater.swift` (`BrewProcessRunner`: timeouts, output draining)
- `PureMac/Views/CategoryDetailView.swift` (review sheet, risk acknowledgements)
- `PureMacTests/DockerSupportTests.swift` (`DockerSupportTests`, `RemovalRiskTests`)
