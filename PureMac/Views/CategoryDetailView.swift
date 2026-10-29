import SwiftUI

struct CategoryDetailView: View {
    private struct CleanupSelection: Identifiable {
        let id = UUID()
        let items: [CleanableItem]
    }

    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: CleaningCategory

    @State private var filter = CleanupReviewFilter()
    @State private var pendingReview: CleanupSelection?
    @State private var acknowledgedRisks: Set<Int> = []
    @State private var confirmingRemoval = false
    @State private var copiedPrompt = false

    private var result: CategoryResult? { appState.categoryResults[category] }
    private var visibleItems: [CleanableItem] { filter.apply(to: result?.items ?? []) }
    private var selectedItems: [CleanableItem] { (result?.items ?? []).filter(appState.isItemSelected) }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    /// Protected and orphan worktrees and explicit-only rows (Docker volumes)
    /// stay visible but never take part in "Select visible".
    private var selectableVisibleItems: [CleanableItem] {
        visibleItems.filter { !$0.isSelectionBlocked && !$0.requiresExplicitSelection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .scanning = appState.scanState {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(Text(LocalizedStringKey(appState.currentScanCategory)))…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop scan") { appState.cancelScan() }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
            if let result, !result.items.isEmpty {
                filters
                Divider()
                if visibleItems.isEmpty {
                    EmptyStateView("No matching files", systemImage: "line.3.horizontal.decrease.circle", description: "Try another name, size, or date range.", action: { filter = CleanupReviewFilter() }, actionLabel: "Clear filters", tint: Tint.teal)
                } else {
                    List(visibleItems) { item in
                        CleanupFileRow(item: item)
                            .listRowSeparator(.visible)
                    }
                    .listStyle(.inset)
                    .disabled(appState.scanState.isActive)
                }
                selectionBar
            } else if result != nil {
                EmptyStateView("No files found", systemImage: "checkmark.circle", description: appState.hasFullDiskAccess ? "There are no cleanup items in this category." : "Some protected locations are unavailable. Full Disk Access allows a more complete scan.", tint: Tint.teal)
            } else if !appState.scanState.isActive {
                EmptyStateView("See what is taking up space", systemImage: category.icon, description: "Scan first, then review the exact files before removing anything.", action: { appState.scanSingleCategory(category) }, actionLabel: "Scan this category", tint: Tint.teal)
            } else {
                Spacer()
            }
        }
        .navigationTitle(Text(LocalizedStringKey(category.rawValue)))
        .sheet(item: $pendingReview) { selection in
            removalReview(items: selection.items)
        }
        .onChange(of: category) { _ in
            filter = CleanupReviewFilter()
            pendingReview = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(systemName: category.icon, tint: Tint.teal, size: 48, corner: 12)
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(category.rawValue))
                    .font(.system(size: 26, weight: .semibold))
                Text(LocalizedStringKey(category.description))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let result {
                    Text("\(result.itemCount) items · \(result.formattedSize) found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let note = result?.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if category == .gitWorktrees {
                    ForEach(appState.lastCleanupNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 16)
            Button {
                appState.scanSingleCategory(category)
            } label: {
                Label(result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(appState.scanState.isActive)
        }
        .padding(28)
    }

    private var filters: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file or path", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter cleanup files")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Picker("Size", selection: $filter.size) {
                    ForEach(CleanupSizeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 180)
                Picker("Modified", selection: $filter.age) {
                    ForEach(CleanupAgeFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 210)
                Spacer(minLength: 0)
                Picker("Sort", selection: $filter.order) {
                    ForEach(CleanupSortOrder.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .frame(maxWidth: 185)
            }
            .controlSize(.small)
            HStack {
                Text("\(visibleItems.count) of \(result?.itemCount ?? 0) items shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Rows that need an explicit click (Docker volumes) or can't be
                // removed at all (protected worktrees) are left out of the bulk
                // selection, but "Deselect visible" clears everything visible.
                let bulkItems = selectableVisibleItems
                let allBulkSelected = bulkItems.allSatisfy(appState.isItemSelected)
                Button(allBulkSelected ? "Deselect visible" : "Select visible") {
                    appState.setSelection(!allBulkSelected, for: allBulkSelected ? visibleItems : bulkItems)
                }
                .disabled(bulkItems.isEmpty || appState.scanState.isActive)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var selectionBar: some View {
        let visibleIDs = Set(visibleItems.map(\.id))
        let hiddenCount = selectedItems.filter { !visibleIDs.contains($0.id) }.count
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectedItems.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("Cleanup permanently removes files unless marked Move to Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hiddenCount > 0 {
                    Text("Includes \(hiddenCount) selected items hidden by filters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !selectedItems.isEmpty {
                Button("Clear selection") { appState.deselectAllInCategory(category) }
                    .buttonStyle(.borderless)
                    .disabled(appState.scanState.isActive)
            }
            if RemovalRisk.requiresAcknowledgement(category) {
                copyPromptButton(proposed: selectedItems)
            }
            Button {
                acknowledgedRisks = []
                pendingReview = CleanupSelection(items: selectedItems)
            } label: {
                Label("Review removal", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.teal)
            .controlSize(.large)
            .disabled(selectedItems.isEmpty || appState.scanState.isActive)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func removalReview(items: [CleanableItem]) -> some View {
        let risks = RemovalRisk.risks(for: category, items: items)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review removal")
                    .font(.title2.weight(.semibold))
                Text("\(items.count) items · \(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("Files and cleanup actions marked Permanent cannot be undone. Items marked Move to Trash can be recovered until the Trash is emptied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(item.name)
                                    .font(.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Text(item.formattedSize)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            if let action = item.dockerPruneAction {
                                Text(action.commandLine)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else if let artifacts = item.worktreeArtifacts {
                                ForEach(artifacts.folders, id: \.relativePath) { folder in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(artifacts.worktreePath + "/" + folder.relativePath)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        Text(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file))
                                            .font(.caption)
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            } else if !item.path.isEmpty {
                                Text(item.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(removalMethod(item))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            if let worktree = item.gitWorktree {
                                Text(worktree.verdict.summary)
                                    .font(.caption)
                                    .foregroundStyle(worktree.verdict.status.tint)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let breakdown = worktree.sizeBreakdownText {
                                    Text(breakdown)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(minHeight: 160, maxHeight: risks.isEmpty ? 300 : 220)
            if !risks.isEmpty {
                riskAcknowledgements(risks)
            }
            HStack {
                if !risks.isEmpty {
                    copyPromptButton(proposed: items)
                }
                Spacer()
                Button("Cancel", role: .cancel) { pendingReview = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(items.count) items", role: .destructive) {
                    if risks.isEmpty {
                        remove(items)
                    } else {
                        confirmingRemoval = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.red)
                .disabled(items.isEmpty || appState.scanState.isActive || acknowledgedRisks.count < risks.count)
                // A tinted prominent button keeps its colour when disabled;
                // dim it so the locked state is visible until every risk is ticked.
                .opacity(acknowledgedRisks.count < risks.count ? 0.45 : 1)
            }
        }
        .padding(24)
        .frame(width: 580)
        .alert(Text("Remove \(items.count) items permanently?"), isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove permanently", role: .destructive) { remove(items) }
        } message: {
            Text("This cannot be undone. Nothing is moved to the Trash.")
        }
    }

    /// Docker and worktree removals delete the user's own work, not caches
    /// an app rebuilds silently: every risk is ticked off before the Remove
    /// button unlocks, and a final alert follows it.
    private func riskAcknowledgements(_ risks: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirm each risk before removing", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Tint.red)
            ForEach(Array(risks.enumerated()), id: \.offset) { index, risk in
                Toggle(isOn: Binding(
                    get: { acknowledgedRisks.contains(index) },
                    set: { if $0 { acknowledgedRisks.insert(index) } else { acknowledgedRisks.remove(index) } }
                )) {
                    Text(risk)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .background(Tint.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Copies a compact review brief for an AI agent: every found item, the
    /// proposed ones marked, and instructions to check read-only and ask the
    /// owner before anything is removed.
    private func copyPromptButton(proposed: [CleanableItem]) -> some View {
        Button {
            let prompt = RemovalRisk.agentPrompt(
                category: category,
                found: result?.items ?? proposed,
                proposed: Set(proposed.map(\.id))
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            copiedPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPrompt = false }
        } label: {
            Label(copiedPrompt ? "Copied" : "Copy agent prompt", systemImage: copiedPrompt ? "checkmark" : "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
        .help("Copy a short brief with every found item so an AI agent can check the risks with you before removal.")
    }

    private func remove(_ items: [CleanableItem]) {
        let itemIDs = Set(items.map(\.id))
        pendingReview = nil
        appState.cleanCategory(category, itemIDs: itemIDs)
    }

    private func removalMethod(_ item: CleanableItem) -> String {
        if item.worktreeArtifacts != nil {
            return String(localized: "Permanent · delete only the git-ignored build folders; the worktree and its tracked files stay")
        }
        if let worktree = item.gitWorktree {
            if worktree.verdict.isPrunableOrphan {
                return String(localized: "Permanent · git worktree prune (forgets the missing folder, deletes no files)")
            }
            if GitWorktreeSettings.current().deleteMergedBranch {
                return String(localized: "Permanent · git worktree remove (merged branch is deleted with git branch -d)")
            }
            return String(localized: "Permanent · git worktree remove (branch is kept)")
        }
        if item.simctlRuntimeIdentifier != nil {
            return String(localized: "Permanent · Remove simulator runtime")
        }
        if item.isActionItem {
            return String(localized: "Permanent · Run cleanup action")
        }
        if XcodeBuildMCPDerivedDataSupport.isManagedDerivedDataPath(item.path) {
            return String(localized: "Move to Trash")
        }
        return String(localized: "Permanent · Delete files")
    }
}

private struct CleanupFileRow: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(item.name)", isOn: appState.itemBinding(for: item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(Tint.teal)
                .disabled(item.isSelectionBlocked)
                .accessibilityLabel("Select \(item.name)")
            Image(systemName: item.worktreeArtifacts != nil ? "shippingbox" : item.gitWorktree != nil ? "arrow.triangle.branch" : item.isActionItem ? "gearshape.2" : "doc")
                .font(.system(size: 18))
                .foregroundStyle(item.worktreeArtifacts != nil ? Tint.accent : Color.secondary)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.dockerPruneAction?.commandLine
                    ?? (item.worktreeArtifacts.map { ($0.worktreePath as NSString).abbreviatingWithTildeInPath }
                        ?? (item.isActionItem ? String(localized: "Managed cleanup action") : (item.path as NSString).abbreviatingWithTildeInPath)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.worktreeArtifacts?.worktreePath ?? item.path)
                if let artifacts = item.worktreeArtifacts {
                    Text(artifacts.folders.map {
                        "\($0.relativePath) \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"
                    }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                    if let blocker = artifacts.blocker {
                        Text(String(localized: "blocked: \(blocker.localizedDescription)"))
                            .font(.system(size: 11))
                            .foregroundStyle(Tint.red)
                            .lineLimit(2)
                    }
                }
                if let worktree = item.gitWorktree, !worktree.verdict.reasons.isEmpty {
                    Text(worktree.verdict.reasons.map(\.localizedDescription).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(worktree.verdict.status.tint)
                        .lineLimit(2)
                }
                if let breakdown = item.gitWorktree?.sizeBreakdownText {
                    Text(breakdown)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let artifacts = item.worktreeArtifacts {
                let blocked = artifacts.blocker != nil
                Text(blocked ? String(localized: "Blocked") : String(localized: "Artifacts"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(blocked ? Tint.red : Tint.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((blocked ? Tint.red : Tint.accent).opacity(0.12), in: Capsule())
                    .help(blocked
                        ? String(localized: "The worktree is busy, so PureMac will not touch its build folders.")
                        : String(localized: "Only git-ignored build folders are deleted. The worktree stays."))
            } else if let worktree = item.gitWorktree {
                Text(worktree.verdict.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(worktree.verdict.status.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(worktree.verdict.status.tint.opacity(0.12), in: Capsule())
                    .help(item.isSelectionBlocked ? String(localized: "PureMac will not remove this worktree.") : worktree.verdict.summary)
            } else if !item.isSelected {
                Text("Review")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .help("Personal data or an optional cleanup action. Left unselected by default.")
            }
            if let date = item.lastModified {
                Text(date, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
            Text(item.formattedSize)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 85, alignment: .trailing)
            if !item.isActionItem || item.worktreeArtifacts != nil {
                Button { reveal() } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(item.name) in Finder")
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, item.worktreeArtifacts != nil ? 18 : 0)
        .contextMenu {
            if !item.isActionItem {
                Button("Reveal in Finder") { reveal() }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
                Divider()
                Button("Always exclude from cleanup") { appState.excludeFromCleanup(item) }
                    .disabled(appState.scanState.isActive)
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.worktreeArtifacts?.worktreePath ?? item.path)])
    }
}

private extension GitWorktreeSupport.Status {
    var tint: Color {
        switch self {
        case .safeToDelete: return .green
        case .needsReview: return .orange
        case .protected: return Tint.red
        case .orphan: return .secondary
        }
    }
}
