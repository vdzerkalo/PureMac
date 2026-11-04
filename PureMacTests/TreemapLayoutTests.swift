import CoreGraphics
import XCTest
@testable import PureMac

final class TreemapLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
    private let epsilon: CGFloat = 1e-6

    // MARK: squarify

    func testNoItemsReturnsNoRects() {
        XCTAssertEqual(TreemapLayout.squarify(sizes: [], in: bounds), [])
    }

    func testZeroNegativeAndNonFiniteSizesGetEmptyRects() {
        let sizes: [Double] = [0, -5, .nan, .infinity]
        XCTAssertEqual(TreemapLayout.squarify(sizes: sizes, in: bounds), [CGRect](repeating: .zero, count: 4))
    }

    func testEmptyOrInvalidBoundsGiveEmptyRects() {
        let sizes: [Double] = [3, 2, 1]
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 300), CGRect(x: 0, y: 0, width: 300, height: -1)] {
            XCTAssertEqual(TreemapLayout.squarify(sizes: sizes, in: invalid), [CGRect](repeating: .zero, count: 3))
        }
    }

    func testSingleItemFillsBounds() {
        let rects = TreemapLayout.squarify(sizes: [42], in: bounds)
        XCTAssertEqual(rects, [bounds])
    }

    func testSingleItemAmongZerosFillsBounds() {
        let rects = TreemapLayout.squarify(sizes: [0, 7, 0], in: bounds)
        XCTAssertEqual(rects[0], .zero)
        XCTAssertEqual(rects[1], bounds)
        XCTAssertEqual(rects[2], .zero)
    }

    func testEqualSizesFormSquaresInInputOrder() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rects = TreemapLayout.squarify(sizes: [1, 1, 1, 1], in: square)
        for rect in rects {
            XCTAssertEqual(rect.width, 50, accuracy: 1e-9)
            XCTAssertEqual(rect.height, 50, accuracy: 1e-9)
        }
        XCTAssertEqual(rects[0].origin, .zero, "ties keep input order, so the first item is placed first")
        assertValidLayout(sizes: [1, 1, 1, 1], rects: rects, in: square)
    }

    func testManyItemsAreProportionalInsideBoundsAndDoNotOverlap() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let sizes = (0..<250).map { _ in Double(Int.random(in: 1...5_000_000, using: &generator)) }
        for candidate in [
            bounds,
            CGRect(x: 40, y: -20, width: 333.5, height: 777.25),
            CGRect(x: 0, y: 0, width: 1000, height: 40)
        ] {
            let rects = TreemapLayout.squarify(sizes: sizes, in: candidate)
            assertValidLayout(sizes: sizes, rects: rects, in: candidate)
        }
    }

    func testSkewedSizesStayValid() {
        // One huge item and a long tail, plus zeros mixed in.
        var sizes: [Double] = [1_000_000_000]
        sizes += (1...200).map { Double($0) }
        sizes.insert(0, at: 17)
        let rects = TreemapLayout.squarify(sizes: sizes, in: bounds)
        assertValidLayout(sizes: sizes, rects: rects, in: bounds)
        XCTAssertEqual(rects[17], .zero)
    }

    func testLayoutIsDeterministic() {
        let sizes: [Double] = [5, 9, 9, 1, 3, 3, 3, 12, 0, 7]
        let first = TreemapLayout.squarify(sizes: sizes, in: bounds)
        for _ in 0..<5 {
            XCTAssertEqual(TreemapLayout.squarify(sizes: sizes, in: bounds), first)
        }
    }

    func testAspectRatiosAreReasonableForTypicalData() {
        // The classic example from the squarified treemap paper.
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(sizes: sizes, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            XCTAssertLessThan(ratio, 3)
        }
    }

    // MARK: model and aggregation

    func testModelWithoutEntriesIsEmpty() {
        XCTAssertTrue(TreemapModel.make(entries: [], in: bounds).tiles.isEmpty)
        XCTAssertTrue(TreemapModel.make(entries: [entry("zero", 0)], in: bounds).tiles.isEmpty)
        XCTAssertTrue(TreemapModel.make(entries: [entry("a", 10)], in: .zero).tiles.isEmpty)
    }

    func testModelWithOneEntryFillsBounds() {
        let model = TreemapModel.make(entries: [entry("only", 123_456)], in: bounds)
        XCTAssertEqual(model.tiles.count, 1)
        XCTAssertEqual(model.tiles[0].rect, bounds)
        XCTAssertEqual(model.tiles[0].entry?.name, "only")
    }

    func testModelDropsZeroSizedEntriesAndOrdersBySizeThenName() {
        let entries = [
            entry("b", 100), entry("empty", 0), entry("a", 100), entry("big", 900)
        ]
        let model = TreemapModel.make(entries: entries, in: bounds)
        XCTAssertEqual(model.tiles.compactMap { $0.entry?.name }, ["big", "a", "b"])
        XCTAssertEqual(model.tiles.map(\.id), [0, 1, 2])
    }

    func testModelIsDeterministicRegardlessOfInputOrder() {
        let entries = (1...40).map { entry("item\($0)", Int64($0 % 7 + 1) * 1_000_000) }
        let forward = TreemapModel.make(entries: entries, in: bounds)
        let backward = TreemapModel.make(entries: entries.reversed(), in: bounds)
        XCTAssertEqual(forward, backward)
    }

    func testSmallEntriesAreMergedIntoOneOtherTile() {
        let large = [entry("big", 5_000_000_000), entry("medium", 3_000_000_000)]
        let tiny = (0..<30).map { entry("tiny\($0)", 1_000) }
        let model = TreemapModel.make(entries: large + tiny, in: bounds)

        XCTAssertEqual(model.tiles.count, 3)
        let others = model.tiles.filter(\.isOther)
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others[0].content, .other(count: 30))
        XCTAssertEqual(others[0].allocatedSize, 30_000)
        XCTAssertEqual(model.tiles.compactMap { $0.entry?.name }, ["big", "medium"])
        assertTilesCoverBounds(model)
    }

    func testEntriesAtOrAboveThresholdStayIndividual() {
        // 4 equal entries in 800x500 are 100,000 pt^2 each.
        let entries = (0..<4).map { entry("e\($0)", 1_000) }
        let kept = TreemapModel.make(entries: entries, in: bounds, minimumTileArea: 100_000)
        XCTAssertEqual(kept.tiles.count, 4)
        XCTAssertTrue(kept.tiles.allSatisfy { !$0.isOther })

        let merged = TreemapModel.make(entries: entries, in: bounds, minimumTileArea: 100_001)
        XCTAssertEqual(merged.tiles.count, 1)
        XCTAssertEqual(merged.tiles[0].content, .other(count: 4))
        XCTAssertEqual(merged.tiles[0].rect, bounds)
    }

    func testSingleSmallEntryIsNotMerged() {
        let entries = [entry("big", 1_000_000_000), entry("small", 1)]
        let model = TreemapModel.make(entries: entries, in: bounds)
        XCTAssertEqual(model.tiles.count, 2)
        XCTAssertTrue(model.tiles.allSatisfy { !$0.isOther })
    }

    func testTileCountIsBoundedByAreaOverThreshold() {
        var generator = SeededGenerator(seed: 42)
        let entries = (0..<5_000).map { entry("f\($0)", Int64.random(in: 1...10_000_000, using: &generator)) }
        let area = bounds.width * bounds.height
        let model = TreemapModel.make(entries: entries, in: bounds)

        XCTAssertLessThanOrEqual(CGFloat(model.tiles.count), area / TreemapModel.defaultMinimumTileArea + 1)
        for tile in model.tiles where !tile.isOther {
            XCTAssertGreaterThanOrEqual(tile.rect.width * tile.rect.height, TreemapModel.defaultMinimumTileArea * 0.999)
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.allocatedSize }
        XCTAssertEqual(model.tiles.reduce(Int64(0)) { $0 + $1.allocatedSize }, total, "aggregation must not lose bytes")
        assertTilesCoverBounds(model)
    }

    func testOtherTileIsSortedBySizeAndLastOnTies() {
        // Five 1-unit entries are merged into Other (size 5), which ties with "five".
        let entries = [entry("ten", 10_000), entry("five", 5_000)] + (0..<5).map { entry("s\($0)", 1_000) }
        let model = TreemapModel.make(entries: entries, in: CGRect(x: 0, y: 0, width: 100, height: 100), minimumTileArea: 1_500)
        XCTAssertEqual(model.tiles.map(\.isOther), [false, false, true])
        XCTAssertEqual(model.tiles.map(\.allocatedSize), [10_000, 5_000, 5_000])
    }

    // MARK: hit-testing

    func testHitTestFindsTileUnderPoint() {
        let model = TreemapModel.make(entries: [entry("a", 600), entry("b", 300), entry("c", 100)], in: bounds, minimumTileArea: 1)
        for tile in model.tiles {
            let center = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
            XCTAssertEqual(model.tile(at: center)?.id, tile.id)
        }
    }

    func testHitTestOutsideBoundsAndEmptyModelReturnNil() {
        let model = TreemapModel.make(entries: [entry("a", 1)], in: bounds)
        XCTAssertNil(model.tile(at: CGPoint(x: -1, y: 10)))
        XCTAssertNil(model.tile(at: CGPoint(x: 10, y: -1)))
        XCTAssertNil(model.tile(at: CGPoint(x: bounds.maxX, y: 10)))
        XCTAssertNil(model.tile(at: CGPoint(x: 10, y: bounds.maxY)))
        XCTAssertNil(model.tile(at: CGPoint(x: CGFloat.nan, y: 10)))
        XCTAssertNil(TreemapModel.make(entries: [], in: bounds).tile(at: CGPoint(x: 5, y: 5)))
    }

    func testHitTestMapsEveryPointToExactlyOneTile() {
        var generator = SeededGenerator(seed: 7)
        let entries = (0..<60).map { entry("f\($0)", Int64.random(in: 1...1_000_000, using: &generator)) }
        let model = TreemapModel.make(entries: entries, in: bounds, minimumTileArea: 100)

        // Includes points exactly on shared tile edges.
        var points = [CGPoint]()
        for tile in model.tiles {
            points.append(tile.rect.origin)
            points.append(CGPoint(x: tile.rect.maxX, y: tile.rect.midY))
            points.append(CGPoint(x: tile.rect.midX, y: tile.rect.maxY))
        }
        for x in stride(from: CGFloat(0), to: bounds.width, by: 13.7) {
            for y in stride(from: CGFloat(0), to: bounds.height, by: 11.3) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        for point in points where point.x < bounds.maxX && point.y < bounds.maxY {
            let containing = model.tiles.filter { tile in
                point.x >= tile.rect.minX && point.x < tile.rect.maxX
                    && point.y >= tile.rect.minY && point.y < tile.rect.maxY
            }
            // Layout rounding can leave a sub-point sliver at the far edge; it must never double-count.
            XCTAssertLessThanOrEqual(containing.count, 1)
            XCTAssertEqual(model.tile(at: point)?.id, containing.first?.id)
        }
    }

    func testHitTestReturnsOtherTile() throws {
        let entries = [entry("big", 5_000_000_000)] + (0..<10).map { entry("tiny\($0)", 10) }
        let model = TreemapModel.make(entries: entries, in: bounds)
        let other = try XCTUnwrap(model.tiles.first(where: \.isOther))
        let center = CGPoint(x: other.rect.midX, y: other.rect.midY)
        XCTAssertEqual(model.tile(at: center)?.content, .other(count: 10))
        XCTAssertNil(model.tile(at: center)?.entry)
    }

    func testHitTestReturnsEntryForDrillDown() throws {
        let folder = entry("Folder", 700, kind: .directory)
        let file = entry("file.bin", 300, kind: .file)
        let model = TreemapModel.make(entries: [folder, file], in: bounds, minimumTileArea: 1)
        let folderTile = try XCTUnwrap(model.tiles.first { $0.entry == folder })
        let hit = model.tile(at: CGPoint(x: folderTile.rect.midX, y: folderTile.rect.midY))
        XCTAssertEqual(hit?.entry?.isDirectory, true)
        XCTAssertEqual(hit?.entry?.url, folder.url)
    }

    // MARK: helpers

    private func entry(_ name: String, _ size: Int64, kind: StorageEntry.Kind = .file) -> StorageEntry {
        StorageEntry(
            url: URL(fileURLWithPath: "/tmp/treemap-fixture/\(name)"),
            kind: kind,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            inaccessibleCount: 0,
            skippedCount: 0
        )
    }

    private func assertTilesCoverBounds(_ model: TreemapModel, file: StaticString = #filePath, line: UInt = #line) {
        let sizes = model.tiles.map { Double($0.allocatedSize) }
        assertValidLayout(sizes: sizes, rects: model.tiles.map(\.rect), in: model.bounds, file: file, line: line)
    }

    /// Areas proportional to sizes, every rect inside `bounds`, no overlaps, full coverage.
    private func assertValidLayout(
        sizes: [Double],
        rects: [CGRect],
        in bounds: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rects.count, sizes.count, file: file, line: line)
        let positive = sizes.enumerated().filter { $0.element.isFinite && $0.element > 0 }
        let total = positive.reduce(0.0) { $0 + $1.element }
        let boundsArea = Double(bounds.width * bounds.height)

        var coveredArea = 0.0
        for (index, size) in positive {
            let rect = rects[index]
            let area = Double(rect.width * rect.height)
            coveredArea += area
            XCTAssertEqual(area / boundsArea, size / total, accuracy: 1e-6, "area of item \(index)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - epsilon, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - epsilon, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + epsilon, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + epsilon, file: file, line: line)
        }
        XCTAssertEqual(coveredArea, boundsArea, accuracy: boundsArea * 1e-9, "tiles cover the bounds", file: file, line: line)

        for (index, size) in sizes.enumerated() where !(size.isFinite && size > 0) {
            XCTAssertEqual(rects[index], .zero, file: file, line: line)
        }

        let placed = positive.map { rects[$0.offset] }
        for first in placed.indices {
            for second in placed.indices where second > first {
                let a = placed[first]
                let b = placed[second]
                let overlapWidth = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let overlapHeight = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                XCTAssertFalse(
                    overlapWidth > epsilon && overlapHeight > epsilon,
                    "rects \(first) and \(second) overlap",
                    file: file,
                    line: line
                )
            }
        }
    }
}

/// Small deterministic generator so fixtures are identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
