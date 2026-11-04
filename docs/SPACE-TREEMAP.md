# Space Explorer treemap

> Read-only treemap mode of Space Explorer: draws the immediate children of a scanned folder as tiles whose area is proportional to allocated size. Code: `PureMac/Services/TreemapLayout.swift` (`TreemapLayout`, `TreemapModel`, `TreemapTile`), `PureMac/Views/Tools/SpaceTreemapView.swift` (`SpaceTreemapView`, `TreemapModelCache`), `PureMac/Views/Tools/SpaceExplorerView.swift` (`DisplayMode`). Tests: `PureMacTests/TreemapLayoutTests.swift`.

## Contents
- [What it finds](#what-it-finds)
- [How it decides](#how-it-decides)
- [How it removes](#how-it-removes)
- [Layout algorithm](#layout-algorithm)
- [Performance](#performance)
- [Safety invariants](#safety-invariants)
- [Failure modes and logs](#failure-modes-and-logs)
- [Testing](#testing)
- [Related](#related)

## What it finds

Nothing of its own. The treemap draws `StorageScanResult.entries`, the sizes `StorageExplorer` already measured (`st_blocks * 512`, hard links counted once, symbolic links and cloud-only items skipped). It performs no filesystem walk, no `stat`, no directory listing. One level is shown: the immediate children of the current folder. Clicking a folder runs the same scan as the list (`SpaceExplorerViewModel.open`).

Where it appears: Space Explorer, after a scan, in the "Largest items" header: segmented control `List | Treemap`. `List` is the default on every launch; the choice is held in view state (`SpaceExplorerView.displayMode`) and is not persisted. The control is hidden when the scan has no entries. No environment variables are read.

## How it decides

| Row | Condition | Drawn as |
|---|---|---|
| Entry with `allocatedSize > 0` and area share >= minimum | `size / total * boundsArea >= minimumTileArea` (576 pt², about 24 x 24) | Own tile |
| Entry with `allocatedSize == 0` | e.g. empty file | Not drawn (still counted by the list) |
| Several small entries | two or more entries below the minimum | One "Other (n items)" tile, size = sum of their sizes |
| One small entry | exactly one entry below the minimum | Own tile (merging one item hides nothing) |
| Directory entry | `StorageEntry.kind == .directory` | Teal (`Tint.accent`); click opens it |
| Package entry | `.package` | Blue (`Tint.blue`); click selects it, no navigation |
| File entry | `.file` | Purple (`Tint.purple`); click selects it |
| "Other" tile | aggregated | Neutral (`Color.secondary`), dashed outline; not clickable |
| Partial entry | `StorageEntry.isPartial` (skipped or inaccessible contents) | Orange corner flag on tiles >= 24 pt, warning icon in the footer |

Hover shows name, size, share of the folder and a partial marker in the footer. Click on a non-folder tile selects it and enables "Show in Finder" in the footer. Right-click on a tile (context menu): "Open Folder" (folders only) and "Show in Finder". The footer note "Skipped and inaccessible items are not included in these sizes." shows when `StorageScanResult.isPartial`.

Nothing is selectable for removal and nothing is preselected.

## How it removes

It does not remove anything. The view receives two closures, `onOpen` (navigate into a folder) and `onReveal` (`NSWorkspace.activateFileViewerSelecting`, via `SpaceExplorerViewModel.reveal`). There is no delete, trash or move action, no confirmation flow and no `FileManager` call in `TreemapLayout.swift` or `SpaceTreemapView.swift`.

## Layout algorithm

`TreemapLayout.squarify(sizes:in:)` implements the squarified treemap of Bruls, Huizing and van Wijk (2000). Original code; no third-party code is included.

1. Input: `[Double]` sizes and a `CGRect`. Output: one `CGRect` per input size, in input order.
2. Items that are zero, negative or not finite get `.zero`. If `bounds.size` is not positive and finite, or no item is positive, every rect is `.zero`. Raw `bounds.size` is used because `CGRect.width`/`height` return absolute values.
3. Placement order: descending size; equal sizes keep input order. Same input gives the same output.
4. Areas are scaled so they sum to the area of `bounds`.
5. Repeatedly take the remaining rectangle, find its short side, and grow a row while the worst aspect ratio `max(w² * rmax / s², s² / (w² * rmin))` does not increase (`w` = short side, `s` = row area sum, `rmax`/`rmin` = largest/smallest area in the row). The row becomes a strip along the short side: a column on the left if the rectangle is wider than tall, otherwise a row at the top. Then continue in the rest.
6. Rounding: positions inside a strip come from cumulative area fractions and the last item of a strip ends exactly at the strip edge; the last strip takes all remaining space. This keeps rects inside `bounds` without gaps or overlaps beyond floating-point error (tests use 1e-6).

`TreemapModel.make(entries:in:minimumTileArea:)` builds tiles:

1. Drop entries with `allocatedSize <= 0`; sort by size descending, ties by `url.path` byte order (cheap and deterministic).
2. Entries whose share of `bounds` area is below `minimumTileArea` form the tail of the sorted list. With two or more, they are merged into one `.other(count:)` tile; its size is the sum, so bytes are conserved.
3. "Other" is inserted at its size-sorted position (last among equals) and everything goes through `squarify`.
4. Tile count is at most `boundsArea / minimumTileArea + 1` (plus at most one lone small entry), regardless of folder size.

`TreemapModel.tile(at:)` is the hit test. It scans `tiles` and returns the first whose rect contains the point, half-open (`minX <= x < maxX`, same for y), so a point on a shared edge belongs to exactly one tile and the far edge of `bounds` hits nothing. The `Canvas` insets drawn rects by 0.75 pt for a visible gap; hit-testing uses the exact model rects.

## Performance

Measured on an Apple M2 Max, Debug test build, 860 x 520 pt bounds, synthetic entries:

| Entries in the folder | `TreemapModel.make` | `tile(at:)` |
|---|---|---|
| 1,000 (356 tiles) | about 3 ms | about 16 µs (linear scan over tiles) |
| 10,000 (aggregated to 1 tile) | about 22 ms | under 1 µs |
| 100,000 (aggregated to 1 tile) | about 370 ms | under 1 µs |

- Cost is dominated by sorting; `squarify` itself is linear in the tile count, which the aggregation threshold bounds.
- `SpaceTreemapView` builds the model once per (entries, rounded size) via `TreemapModelCache`; hover changes only repaint the `Canvas`. Hover updates `@State` only when the tile under the pointer changes.
- Resizing the window rebuilds the model for each new size. For a folder with ~100,000 direct children this is visible; no mitigation beyond the cache exists.
- Canvas paints at most ~700 tiles (default bounds area / 576) plus labels for tiles at least 52 x 22 pt.
- No extra I/O: the scan itself is unchanged.

## Safety invariants

1. The treemap cannot change files: `SpaceTreemapView` only has `onOpen` and `onReveal`; `TreemapLayout.swift` imports only `CoreGraphics` and `Foundation` and uses no file API. Check: `grep -nE "removeItem|trashItem|moveItem|FileManager|NSWorkspace" PureMac/Views/Tools/SpaceTreemapView.swift PureMac/Services/TreemapLayout.swift` returns nothing. No test covers this; it is a review check.
2. No new filesystem access: the model is built from `StorageEntry` values. Proof: `TreemapLayoutTests` build models from entries whose paths do not exist (`/tmp/treemap-fixture/...`).
3. Skipped and inaccessible handling is inherited: sizes already exclude them (`StorageExplorer`, tests in `StorageExplorerTests.swift`); the treemap flags partial entries (`SpaceTreemapView` → `draw`, `footer`). The flag rendering has no unit test.
4. Aggregation conserves bytes: `TreemapModel` → `make`; `testTileCountIsBoundedByAreaOverThreshold`, `testSmallEntriesAreMergedIntoOneOtherTile`.
5. Layout is valid for any input (proportional areas, inside bounds, no overlaps, full coverage): `TreemapLayout` → `squarify`; `testManyItemsAreProportionalInsideBoundsAndDoNotOverlap`, `testSkewedSizesStayValid`, `testEqualSizesFormSquaresInInputOrder`.
6. Degenerate input yields empty rects, never a crash: `testNoItemsReturnsNoRects`, `testZeroNegativeAndNonFiniteSizesGetEmptyRects`, `testEmptyOrInvalidBoundsGiveEmptyRects`, `testModelWithoutEntriesIsEmpty`.
7. Hit-testing runs on the model and is unambiguous: `TreemapModel` → `tile(at:)`; `testHitTestMapsEveryPointToExactlyOneTile`, `testHitTestOutsideBoundsAndEmptyModelReturnNil`, `testHitTestReturnsOtherTile`, `testHitTestReturnsEntryForDrillDown`.
8. Only real folders are navigable: `SpaceTreemapView` → `activate` calls `onOpen` only for `StorageEntry.isDirectory`, and `SpaceExplorerViewModel.open` guards again; packages, files and "Other" are never opened. Not unit-tested (view code).
9. Accessibility: `Canvas` is not exposed to VoiceOver, so `SpaceTreemapView` uses `accessibilityRepresentation` with a list of one row per tile (name, size, kind, partial note; folders are buttons that open, entries have a "Show in Finder" action). Verified by code review only, not with VoiceOver.
10. Colours come from `Tint` and system styles, labels use `.primary`/`.secondary` text on translucent fills so contrast follows the appearance. Checked by rendering the view offscreen in light and dark mode (`ImageRenderer`), not by a test.

## Failure modes and logs

The treemap logs nothing (`Logger` is not used); failures surface as scan errors from Space Explorer.

| Symptom | Cause | Where to look |
|---|---|---|
| Whole map is one "Other" tile | Many small children relative to the drawing area; every child is below 576 pt² | `TreemapModel.defaultMinimumTileArea`; open the folder with `List` to see items |
| A tile is missing | Its `allocatedSize` is 0, or it was skipped/inaccessible during the scan | `StorageExplorer.measure`; the footer partial note |
| Orange corner on a tile | Entry has `skippedCount` or `inaccessibleCount` > 0 | `StorageEntry.isPartial` |
| Clicking a tile does nothing visible | Tile is a file, package or "Other": click selects, no navigation | `SpaceTreemapView.activate` |
| Treemap segment is not shown | Scan returned no entries, or scan is running/failed | `SpaceExplorerView.resultView` |
| Slow redraw while resizing a huge folder | Model rebuilt per size; sort is O(n log n) | [Performance](#performance) |
| Labels cut off | Tile text is clipped to the tile; names are not truncated with an ellipsis | `SpaceTreemapView.draw` |
| Tooltip-style text missing near cursor | Hover info is shown in the footer, not as a floating tooltip | `SpaceTreemapView.footer` |

## Testing

```
xcodegen generate
xcodebuild test -project PureMac.xcodeproj -scheme PureMac -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/fork-space-treemap-dd" CODE_SIGNING_ALLOWED=NO \
  -only-testing:PureMacTests/TreemapLayoutTests
```

- 24 tests, all on pure values: layout for 0, 1 and many items, proportional areas, containment, no overlaps, determinism, aggregation threshold, hit-testing. Fixtures are in-memory `StorageEntry` values with non-existent paths and a seeded random generator; nothing touches the disk.
- Localization parity: `LocalizationFilesTests` (new keys are under `/* Space Explorer treemap */` in all 13 `Localizable.strings`).
- Manual run against a fake home: create a fixture folder with a few files and subfolders under `$TMPDIR`, then
  `CFFIXED_USER_HOME=<fixture-home> <DerivedData>/Build/Products/Debug/PureMac.app/Contents/MacOS/PureMac`
  Open Space Explorer, choose the fixture folder, switch to Treemap, hover tiles, click a folder, right-click for Show in Finder. Do not use any Clean action.

## Related

- [README](../README.md), "Space Explorer" paragraph
- `PureMac/Services/StorageExplorer.swift` (`StorageExplorer`, `StorageEntry`, `StorageScanResult`): the only source of sizes
- `PureMac/Views/Tools/SpaceExplorerView.swift`: list mode, navigation, toggle
- `PureMac/Views/Components/AppTheme.swift` (`Tint`): colours
- Upstream discussion: momenbasel/PureMac #148 (closed as not planned; this feature lives in the fork)
