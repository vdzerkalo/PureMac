import Foundation

/// User choices for the Git Worktrees category (Settings → Cleaning). Read
/// from UserDefaults at scan time and again at clean time, so the re-check
/// before a removal judges the worktree by the same rules the scan did.
struct GitWorktreeSettings: Equatable {
    static let inactiveDaysKey = "settings.cleaning.worktrees.inactiveDays"
    static let extraRootsKey = "settings.cleaning.worktrees.extraRoots"
    static let baseBranchKey = "settings.cleaning.worktrees.baseBranch"
    static let deleteMergedBranchKey = "settings.cleaning.worktrees.deleteMergedBranch"
    /// Manual Smart Scan also scans worktrees (`CleaningCategory.smartScanOptInKey`).
    static let includeInSmartScanKey = "settings.cleaning.worktrees.includeInSmartScan"
    static let inactiveDaysRange = 1...365

    /// Days without activity before a merged worktree counts as idle.
    var inactiveDays = GitWorktreeSupport.defaultInactiveDays
    /// Absolute folders searched for repositories besides the built-in
    /// agent folders and Claude Code's project list.
    var extraRoots: [String] = []
    /// Revision merged-ness is judged against; empty means the automatic
    /// order (origin/HEAD, origin/main, origin/master, main, master).
    var baseBranch = ""
    /// Run `git branch -d` for the branch of a removed Safe-to-delete worktree.
    var deleteMergedBranch = false

    static func current(defaults: UserDefaults = .standard) -> GitWorktreeSettings {
        var settings = GitWorktreeSettings()
        if let days = defaults.object(forKey: inactiveDaysKey) as? Int {
            settings.inactiveDays = min(max(days, inactiveDaysRange.lowerBound), inactiveDaysRange.upperBound)
        }
        settings.extraRoots = (defaults.stringArray(forKey: extraRootsKey) ?? [])
            .filter { $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0") }
        settings.baseBranch = (defaults.string(forKey: baseBranchKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        settings.deleteMergedBranch = defaults.bool(forKey: deleteMergedBranchKey)
        return settings
    }
}
