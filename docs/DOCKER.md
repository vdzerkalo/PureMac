# Docker Cache

> Docker Cache category: file caches of Docker Desktop and OrbStack plus five virtual rows, each one `docker ... prune` command. Code: `PureMac/Logic/Utilities/DockerSupport.swift` (`PruneAction`, `pruneEstimates`, `danglingEstimate`), `PureMac/Services/ScanEngine.swift` (`scanDockerCache`), `PureMac/Services/CleaningEngine.swift` (`pruneDocker`), `PureMac/Logic/Utilities/RemovalRisk.swift`. Tests: `PureMacTests/DockerSupportTests.swift`.

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
| Unused Docker volumes (may contain data such as databases) | `docker volume prune -a -f` | df `Local Volumes` Reclaimable > 0 | df Reclaimable | no, and skipped by "Select visible" and the category checkbox (`requiresExplicitSelection`); only a click on the row selects it |

The file rows are selected by default; every virtual row is not. Scheduled auto-clean (`AppState.cleanAll(scheduled:)`) scans first and cleans only selected rows; a fresh scan returns every virtual row unselected, so a scheduled run does not run a prune.

### Estimate sources and why they are conservative

- **df rows** (`docker system df --format '{{json .}}'`, `DockerSupport.parseSystemDF`): the `Reclaimable` column, percentage ignored. Docker rounds these values to 4 significant digits.
- **Dangling images** (`DockerSupport.danglingEstimate`). The image IDs come from `docker images --filter dangling=true --no-trunc --format '{{.ID}}'`, the same filter `image prune -f` applies. The bytes come from `docker system df -v --format '{{json .}}'` (Images array), matched by ID:
  - an image's `UniqueSize` counts only layers no other image uses, so deleting the image frees at least that. `Size` is not used because it includes shared layers;
  - images with `Containers` > 0 (a stopped container counts) are skipped: prune keeps them;
  - layers shared only between dangling images, or with an image deleted in the same run, are not counted. The figure can be too low, never too high (apart from Docker's rounding);
  - df's own `<none>:<none>` rows are not used to find dangling images. On the containerd image store (Docker Desktop 29, seen on a real install) df -v lists digest-only references such as `repo@sha256:...` as `<none>:<none>`, and `image prune -f` keeps those.
  - If `df -v` fails or times out, the row is still offered (the filter found images) with size 0 and the "size not estimated" label. If the filter command fails, no dangling row appears.
- **Both image rows selected.** The `-a` command also removes dangling images, so its df figure already contains them. To keep the sum honest, the `-a` row shows df Reclaimable minus the dangling estimate (never below 0; the row is hidden at 0). Selected alone, the `-a` row therefore under-promises by the dangling estimate; selected together the sum equals df's figure. If the dangling size is unknown the `-a` row shows df's figure unchanged and the dangling row shows 0, so nothing is counted twice.
- **No `docker system prune`.** It would remove things the rows do not list (networks) and would hide per-row choice.

## How it removes

Each selected virtual row runs its own command through `BrewProcessRunner` (stdout and stderr drained, timeout enforced, process terminated then SIGKILLed on timeout). No file is unlinked for these rows and nothing goes to the Trash.

Run order, not display order (`PruneAction.cleanOrder`, applied by `DockerSupport.orderedForCleaning` at the start of `CleaningEngine.cleanItems`):

1. `docker container prune -f`: releases images and volumes held by stopped containers, so the next commands find more. Estimates only under-promise because of this.
2. `docker image prune -f`
3. `docker image prune -a -f`: runs after the dangling prune, so it reports only what is left.
4. `docker volume prune -a -f`
5. `docker builder prune -a -f`: independent and can run for minutes, so last.

Non-Docker items keep their position; Docker rows only swap among the slots Docker rows already had.

**Freed space.** `DockerSupport.parseReclaimedSpace` reads the last `Total reclaimed space: N` line (container, image, volume prune) or `Total:\tN` line (builder prune) from each command. Every command prints only what it removed itself, so the totals add up without overlap; a command with no summary line counts 0.

**What is removed and what never is**

| Command | Removes | Never removes |
|---|---|---|
| `docker builder prune -a -f` | all build cache not in use | cache of a build running right now |
| `docker container prune -f` | all stopped containers and their writable layers | running containers |
| `docker image prune -f` | images with no tag and no digest reference, not used by any container | tagged images; images any container (even stopped) uses |
| `docker image prune -a -f` | every image no container uses, tagged or not (includes dangling) | images any container uses |
| `docker volume prune -a -f` | every local volume no container uses, named and anonymous: **data is erased** | volumes a container (even stopped) references |

Per Docker's CLI definitions; PureMac relies on the daemon for these rules and does not re-implement them.

**Review sheet.** `RemovalRisk.risks(for: .dockerCache, items:)` lists one risk per selected kind of row, all of which must be ticked before Remove unlocks: always "Nothing goes to the Trash"; then, only when selected, build cache (next build is slower), stopped containers (deleted with their files), images (`-a`: all unused images, tagged or not; locally built ones can only be rebuilt) or, if `-a` is not selected, dangling images (rebuild from source), and volumes (erased with their data). "Copy agent prompt" lists every found row with its exact command.

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

1. Only five fixed argument lists are ever run, and never `system prune`: `DockerSupport.PruneAction.arguments`. Test: `testPruneActionArgumentsMatchWhatDfCountsAsReclaimable`.
2. Virtual rows are never preselected and volumes need an explicit click: `ScanEngine.swift` → `scanDockerCache` (`isSelected: false`), `PruneAction.requiresExplicitSelection`, `AppState.selectAllInCategory`. Tests: `testOnlyVolumesRequireExplicitSelection`, `testPruneRowsAreActionItems`.
3. Virtual rows never reach the unlink path: `CleaningEngine.swift` → `cleanItems` routes `dockerPruneAction` before any file deletion; `CleanableItem.isActionItem` hides reveal-in-Finder. Docker.raw is never an item.
4. A size is never larger than what the command frees: `DockerSupport.danglingEstimate` (unique size, skips in-use images, dangling IDs from the prune filter) and `DockerSupport.pruneEstimates` (disjoint image rows, never negative). Tests: `testDanglingEstimateCountsUniqueSizeOfUnusedDanglingImagesOnly`, `testPruneEstimatesMakeTheTwoImageRowsDisjoint`, `testImagesRowNeverGoesNegative`.
5. An unknown size is shown as 0 with a label, not guessed: `pruneEstimates` (`sizeKnown`), `ScanEngine.dockerPruneItemName`. Tests: `testDanglingRowWithoutAFigureIsLabelledUnknownAndKeepsTheImagesRow`, `testDanglingEstimateHasNoSizeWhenVerboseDFIsUnavailable`.
6. Selected rows run in a fixed order and freed bytes add up from per-command output: `PruneAction.cleanOrder`, `DockerSupport.orderedForCleaning`. Tests: `testCleanOrderRunsContainersThenDanglingThenAllImagesThenVolumesThenBuildCache`, `testOrderedForCleaningOnlyMovesDockerRowsWithinTheirOwnSlots`, `testCleanRunsSelectedPrunesInOrderAndSumsFreedSpaceWithoutOverlap`.
7. The user acknowledges the risks of exactly the selected rows: `RemovalRisk.risks`. Tests: `testRisksMatchTheSelectedRowsExactly`, `testRiskTextsNameWhatTheCommandRemoves`.
8. Every docker call has a timeout (10 s `df`, 30 s each dangling lookup, 900 s prune), so a wedged daemon cannot hang a scan or clean: `ScanEngine.swift` → `dockerDiskUsage`, `dockerDanglingEstimate`; `DockerSupport.pruneTimeout`, `danglingLookupTimeout`.
9. Tests never run a real docker: `CleaningEngine(homeDirectory:dockerBinaryPath:)` takes a fake CLI script path (`makeFakeDocker`); pure parsing is tested on captured output.

## Failure modes and logs

Logs go through `Logger.shared.log(...)` (Console.app, subsystem = the app bundle id, category `general`; also the in-app log).

| Symptom | Cause | Where to look |
|---|---|---|
| No virtual rows, no note about Docker | No docker binary at the five paths; daemon not running; `docker system df` exited non-zero (silent, no log); more than 10 s | Run `docker system df` yourself. Timeout or launch error logs: `docker system df failed: <error>` (warning), where a timeout reads `Homebrew did not finish before the operation timed out.` (shared runner text) |
| No dangling row although `docker images -f dangling=true` lists images | The filter command failed or timed out (30 s) | Log `docker images --filter dangling=true failed: <error>` (warning); a non-zero exit is silent |
| Dangling row says "size not estimated" | `docker system df -v` failed, timed out (30 s), returned unparseable JSON, or all the images' layers are shared (unique size 0) | Log `docker system df -v failed: <error>` (warning) for failures; the other cases log nothing |
| Clean error `Docker CLI not found — install Docker Desktop or OrbStack` | Binary vanished between scan and clean | `DockerSupport.candidateBinaryPaths` |
| Clean error `Docker isn't running — start Docker Desktop or OrbStack, then clean again` | Prune exited non-zero and stderr contains `Cannot connect`, `dial unix` or `daemon` (`DockerSupport.isDaemonUnavailable`) | Start the daemon; no log line |
| Clean error `<command> did not finish in time — check Docker Desktop or OrbStack, then clean again` | A prune ran past 900 s (daemon or CLI hang); the process is terminated, then SIGKILLed | Log `<command> timed out after 900s` (error) |
| Clean error `Couldn't run <command>: <error>` | The binary could not be launched | Log `<command> failed to launch: <error>` (error) |
| Clean error `<command> failed (exit N)` | Prune exited non-zero for another reason | Log `<command> exited N: <stderr>` (error) |
| Row cleaned but freed bytes show 0 | Command printed no `Total reclaimed space:` / `Total:` line, or nothing was removed | Log `<command> reclaimed N bytes` (info) |
| Docker.raw does not shrink after a clean | See [above](#dockerraw-and-returning-space-to-macos): up to a few minutes; images must actually have been deleted | `du -h` or `ls -klsh` on Docker.raw |

`<command>` is the exact command line, for example `docker image prune -f`. If one prune of several fails, the others still run (each row reports its own error); the row that failed stays in the list.

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
