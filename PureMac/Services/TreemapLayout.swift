import CoreGraphics
import Foundation

/// Pure squarified-treemap layout (Bruls, Huizing, van Wijk, "Squarified Treemaps", 2000).
/// No UI, no filesystem access: sizes and a rectangle in, rectangles out.
enum TreemapLayout {
    /// Lays out `sizes` inside `bounds`.
    ///
    /// - Returns: one rectangle per input size, in input order. Each rectangle's area is
    ///   proportional to its size. Sizes that are zero, negative or not finite get `.zero`.
    ///   Everything is `.zero` when `bounds` has no area or there is nothing to place.
    /// - Order: items are placed from largest to smallest; ties keep input order, so the
    ///   same input always yields the same output.
    static func squarify(sizes: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: sizes.count)

        let width = Double(bounds.size.width)
        let height = Double(bounds.size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return result }

        let order = sizes.indices
            .filter { sizes[$0].isFinite && sizes[$0] > 0 }
            .sorted { lhs, rhs in
                sizes[lhs] == sizes[rhs] ? lhs < rhs : sizes[lhs] > sizes[rhs]
            }
        guard !order.isEmpty else { return result }

        let total = order.reduce(0.0) { $0 + sizes[$1] }
        guard total.isFinite, total > 0 else { return result }

        let scale = width * height / total
        let areas = order.map { sizes[$0] * scale }

        var remaining = bounds
        var start = 0
        while start < areas.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            guard shortSide > 0 else { break }

            // Grow the row while the worst aspect ratio does not get worse.
            var end = start + 1
            var rowSum = areas[start]
            while end < areas.count {
                let nextSum = rowSum + areas[end]
                let current = worstRatio(first: areas[start], last: areas[end - 1], sum: rowSum, side: shortSide)
                let candidate = worstRatio(first: areas[start], last: areas[end], sum: nextSum, side: shortSide)
                if candidate > current { break }
                rowSum = nextSum
                end += 1
            }

            let isLastRow = end == areas.count
            let horizontal = remaining.width >= remaining.height
            // The row occupies a strip along the short side of `remaining`.
            let strip = horizontal ? remaining.width : remaining.height
            let thickness = isLastRow
                ? strip
                : min(strip, CGFloat(rowSum / shortSide))
            let length = horizontal ? remaining.height : remaining.width

            var cursor = CGFloat(0)
            var accumulated = 0.0
            for index in start..<end {
                accumulated += areas[index]
                let next = index == end - 1
                    ? length
                    : min(length, CGFloat(accumulated / rowSum) * length)
                let rect: CGRect
                if horizontal {
                    rect = CGRect(
                        x: remaining.minX,
                        y: remaining.minY + cursor,
                        width: thickness,
                        height: next - cursor
                    )
                } else {
                    rect = CGRect(
                        x: remaining.minX + cursor,
                        y: remaining.minY,
                        width: next - cursor,
                        height: thickness
                    )
                }
                result[order[index]] = rect
                cursor = next
            }

            if horizontal {
                remaining = CGRect(
                    x: remaining.minX + thickness,
                    y: remaining.minY,
                    width: max(0, remaining.width - thickness),
                    height: remaining.height
                )
            } else {
                remaining = CGRect(
                    x: remaining.minX,
                    y: remaining.minY + thickness,
                    width: remaining.width,
                    height: max(0, remaining.height - thickness)
                )
            }
            start = end
        }

        return result
    }

    /// Worst aspect ratio of a row whose areas are sorted descending (`first` is the largest,
    /// `last` the smallest) and sum to `sum`, laid along a side of length `side`.
    private static func worstRatio(first: Double, last: Double, sum: Double, side: Double) -> Double {
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * first / sumSquared, sumSquared / (sideSquared * last))
    }
}

/// One drawable, hit-testable rectangle of a treemap.
struct TreemapTile: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// A single item from the scan.
        case entry(StorageEntry)
        /// Several items too small to draw on their own, merged into one tile.
        case other(count: Int)
    }

    /// Index in `TreemapModel.tiles`.
    let id: Int
    let rect: CGRect
    let content: Content
    let allocatedSize: Int64

    var entry: StorageEntry? {
        if case .entry(let entry) = content { return entry }
        return nil
    }

    var isOther: Bool {
        if case .other = content { return true }
        return false
    }
}

/// Treemap of one folder's immediate children, built from sizes the scan already measured.
/// Hit-testing runs against this model, not against views.
struct TreemapModel: Equatable, Sendable {
    /// Default area, in points squared, under which a tile is merged into "Other" (about 24 x 24).
    static let defaultMinimumTileArea: CGFloat = 576

    let bounds: CGRect
    let tiles: [TreemapTile]

    /// - Parameters:
    ///   - entries: immediate children of the scanned folder. Entries with no allocated size are not drawn.
    ///   - bounds: drawing area.
    ///   - minimumTileArea: entries whose share of `bounds` is smaller than this are merged into one
    ///     "Other" tile. A single small entry stays as it is, because merging one item hides nothing.
    ///     This also bounds the tile count by `bounds` area / `minimumTileArea` plus one.
    static func make(
        entries: [StorageEntry],
        in bounds: CGRect,
        minimumTileArea: CGFloat = defaultMinimumTileArea
    ) -> TreemapModel {
        let measured = entries
            .filter { $0.allocatedSize > 0 }
            .sorted(by: isOrderedBefore)
        let totalSize = measured.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let boundsArea = Double(bounds.size.width) * Double(bounds.size.height)
        guard !measured.isEmpty, totalSize > 0, bounds.size.width > 0, bounds.size.height > 0, boundsArea.isFinite else {
            return TreemapModel(bounds: bounds, tiles: [])
        }

        let areaPerByte = boundsArea / Double(totalSize)
        let threshold = Double(max(0, minimumTileArea))
        let isSmall: (StorageEntry) -> Bool = { Double($0.allocatedSize) * areaPerByte < threshold }

        // `measured` is sorted by size, so the small items form its tail.
        let firstSmall = measured.firstIndex(where: isSmall) ?? measured.count
        let smallCount = measured.count - firstSmall

        struct Item {
            let content: TreemapTile.Content
            let size: Int64
        }
        var items = measured[..<firstSmall].map { Item(content: .entry($0), size: $0.allocatedSize) }
        if smallCount >= 2 {
            let otherSize = measured[firstSmall...].reduce(Int64(0)) { $0 + $1.allocatedSize }
            let other = Item(content: .other(count: smallCount), size: otherSize)
            // Keep the list sorted by size; on equal size "Other" goes last.
            let position = items.firstIndex(where: { $0.size < otherSize }) ?? items.count
            items.insert(other, at: position)
        } else {
            items.append(contentsOf: measured[firstSmall...].map { Item(content: .entry($0), size: $0.allocatedSize) })
        }

        let rects = TreemapLayout.squarify(sizes: items.map { Double($0.size) }, in: bounds)
        let tiles = items.indices.map {
            TreemapTile(id: $0, rect: rects[$0], content: items[$0].content, allocatedSize: items[$0].size)
        }
        return TreemapModel(bounds: bounds, tiles: tiles)
    }

    /// The tile under `point`, or nil. Tiles are half-open (`minX <= x < maxX`), so a point
    /// on a shared edge belongs to exactly one tile.
    func tile(at point: CGPoint) -> TreemapTile? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return tiles.first { tile in
            let rect = tile.rect
            return !rect.isEmpty
                && point.x >= rect.minX && point.x < rect.maxX
                && point.y >= rect.minY && point.y < rect.maxY
        }
    }

    private static func isOrderedBefore(_ lhs: StorageEntry, _ rhs: StorageEntry) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
        // Byte-order path comparison: deterministic, and much cheaper than a localized name compare on huge folders.
        return lhs.url.path < rhs.url.path
    }
}
