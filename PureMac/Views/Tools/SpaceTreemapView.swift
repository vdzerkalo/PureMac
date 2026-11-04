import AppKit
import SwiftUI

/// Treemap view of a Space Explorer scan. Read-only: it can open a folder (same navigation as the
/// list) and reveal an item in Finder; it has no way to delete, move or trash anything.
/// Layout and hit-testing come from `TreemapModel`; the `Canvas` only paints that model.
struct SpaceTreemapView: View {
    let result: StorageScanResult
    let onOpen: (StorageEntry) -> Void
    let onReveal: (URL) -> Void

    @State private var cache = TreemapModelCache()
    @State private var hoveredID: Int?
    @State private var selectedURL: URL?
    @Environment(\.colorScheme) private var colorScheme

    private static let footerHeight: CGFloat = 44
    private static let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let mapSize = CGSize(
                width: max(1, proxy.size.width),
                height: max(120, proxy.size.height - Self.footerHeight - Self.spacing)
            )
            let model = cache.model(entries: result.entries, size: mapSize)
            let hovered = tile(withID: hoveredID, in: model)
            let selected = selectedURL.flatMap { url in model.tiles.first { $0.entry?.url == url } }

            VStack(alignment: .leading, spacing: Self.spacing) {
                treemap(model: model, hovered: hovered, selected: selected)
                    .frame(width: mapSize.width, height: mapSize.height)
                footer(hovered: hovered, selected: selected)
                    .frame(height: Self.footerHeight, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }

    // MARK: Canvas

    private func treemap(model: TreemapModel, hovered: TreemapTile?, selected: TreemapTile?) -> some View {
        Canvas { context, _ in
            for tile in model.tiles {
                draw(
                    tile,
                    in: &context,
                    isHovered: tile.id == hovered?.id,
                    isSelected: tile.id == selected?.id
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            let id: Int?
            switch phase {
            case .active(let location): id = model.tile(at: location)?.id
            case .ended: id = nil
            }
            if id != hoveredID { hoveredID = id }
        }
        .gesture(
            SpatialTapGesture().onEnded { value in
                activate(model.tile(at: value.location))
            }
        )
        .contextMenu {
            if let entry = hovered?.entry {
                if entry.isDirectory {
                    Button("Open Folder") { onOpen(entry) }
                }
                Button("Show in Finder") { onReveal(entry.url) }
            }
        }
        .accessibilityRepresentation {
            List(model.tiles) { tile in
                accessibilityRow(tile)
            }
            .accessibilityLabel("Treemap of allocated space")
        }
    }

    private func draw(_ tile: TreemapTile, in context: inout GraphicsContext, isHovered: Bool, isSelected: Bool) {
        let rect = tile.rect.insetBy(dx: 0.75, dy: 0.75)
        guard rect.width > 1, rect.height > 1 else { return }

        let tint = Self.tint(for: tile)
        let isDark = colorScheme == .dark
        let fillOpacity = (isDark ? 0.34 : 0.24) + (isHovered ? 0.16 : 0)
        let path = Path(roundedRect: rect, cornerRadius: min(5, rect.width / 3, rect.height / 3), style: .continuous)

        context.fill(path, with: .color(tint.opacity(fillOpacity)))
        if tile.isOther {
            context.stroke(
                path,
                with: .color(tint.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        } else {
            context.stroke(
                path,
                with: .color(tint.opacity(isHovered || isSelected ? 1 : 0.55)),
                lineWidth: isHovered || isSelected ? 2 : 1
            )
        }

        var clipped = context
        clipped.clip(to: path)

        if tile.entry?.isPartial == true, rect.width >= 24, rect.height >= 24 {
            var flag = Path()
            flag.move(to: CGPoint(x: rect.maxX - 12, y: rect.minY))
            flag.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            flag.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 12))
            flag.closeSubpath()
            clipped.fill(flag, with: .color(Tint.orange))
        }

        guard rect.width >= 52, rect.height >= 22 else { return }
        let title = clipped.resolve(
            Text(Self.title(for: tile))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
        )
        clipped.draw(title, at: CGPoint(x: rect.minX + 7, y: rect.minY + 5), anchor: .topLeading)

        if rect.height >= 40 {
            let size = clipped.resolve(
                Text(Self.format(tile.allocatedSize))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            )
            clipped.draw(size, at: CGPoint(x: rect.minX + 7, y: rect.minY + 22), anchor: .topLeading)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(hovered: TreemapTile?, selected: TreemapTile?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let tile = hovered ?? selected {
                    Image(systemName: Self.symbol(for: tile))
                        .foregroundStyle(Self.tint(for: tile))
                    Text(Self.title(for: tile))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.format(tile.allocatedSize))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(share(of: tile))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if tile.entry?.isPartial == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Tint.orange)
                            .help("Some contents were skipped or inaccessible")
                    }
                    if tile.isOther {
                        Text("Items too small to draw individually are grouped into this tile.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Hover a tile to see its name and size. Click a folder to open it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let entry = selected?.entry {
                    Button {
                        onReveal(entry.url)
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show \(entry.name) in Finder")
                }
            }

            if result.isPartial {
                Text("Skipped and inaccessible items are not included in these sizes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Tint.orange)
            }
        }
    }

    // MARK: Interaction

    private func activate(_ tile: TreemapTile?) {
        guard let entry = tile?.entry else {
            selectedURL = nil
            return
        }
        if entry.isDirectory {
            onOpen(entry)
        } else {
            selectedURL = entry.url
        }
    }

    private func tile(withID id: Int?, in model: TreemapModel) -> TreemapTile? {
        guard let id, model.tiles.indices.contains(id) else { return nil }
        return model.tiles[id]
    }

    private func share(of tile: TreemapTile) -> String {
        guard result.totalAllocatedSize > 0 else { return "" }
        let fraction = Double(tile.allocatedSize) / Double(result.totalAllocatedSize)
        return fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }

    // MARK: Accessibility

    @ViewBuilder
    private func accessibilityRow(_ tile: TreemapTile) -> some View {
        if let entry = tile.entry {
            Button {
                activate(tile)
            } label: {
                Text(Self.accessibilityLabel(for: tile))
            }
            .accessibilityAction(named: Text("Show in Finder")) { onReveal(entry.url) }
        } else {
            Text(Self.accessibilityLabel(for: tile))
        }
    }

    // MARK: Presentation

    static func title(for tile: TreemapTile) -> String {
        switch tile.content {
        case .entry(let entry): return entry.name
        case .other(let count): return String(localized: "Other (\(count) items)")
        }
    }

    static func accessibilityLabel(for tile: TreemapTile) -> String {
        var parts = [title(for: tile), format(tile.allocatedSize)]
        if let entry = tile.entry {
            parts.append(kindLabel(entry))
            if entry.isPartial {
                parts.append(String(localized: "Some contents were skipped or inaccessible"))
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func kindLabel(_ entry: StorageEntry) -> String {
        switch entry.kind {
        case .directory: return String(localized: "Folder")
        case .package: return String(localized: "Package")
        case .file: return String(localized: "File")
        }
    }

    private static func symbol(for tile: TreemapTile) -> String {
        guard let entry = tile.entry else { return "square.grid.2x2.fill" }
        switch entry.kind {
        case .directory: return "folder.fill"
        case .package: return "app.fill"
        case .file: return "doc.fill"
        }
    }

    /// Folder, package and file tiles use different theme tints; "Other" is neutral.
    private static func tint(for tile: TreemapTile) -> Color {
        guard let entry = tile.entry else { return .secondary }
        switch entry.kind {
        case .directory: return Tint.accent
        case .package: return Tint.blue
        case .file: return Tint.purple
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Keeps the last `TreemapModel` so hover changes repaint without re-sorting every entry.
/// A plain reference type on purpose: mutating it during `body` must not invalidate the view.
final class TreemapModelCache {
    private struct Key: Equatable {
        let width: CGFloat
        let height: CGFloat
        let fingerprint: Int
    }

    private var key: Key?
    private var model: TreemapModel?

    func model(entries: [StorageEntry], size: CGSize) -> TreemapModel {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.url)
            hasher.combine(entry.allocatedSize)
        }
        let newKey = Key(width: size.width.rounded(), height: size.height.rounded(), fingerprint: hasher.finalize())
        if let key, key == newKey, let model { return model }

        let built = TreemapModel.make(entries: entries, in: CGRect(origin: .zero, size: CGSize(width: newKey.width, height: newKey.height)))
        key = newKey
        model = built
        return built
    }
}
