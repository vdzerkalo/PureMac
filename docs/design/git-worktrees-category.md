# Design: "Git Worktrees" cleaning category

Status: **approved by the user (2026-10-29), see "Decisions".** Next it goes to upstream as an issue. Nothing is implemented yet.
This text is meant to become the upstream issue we open before PR 2 (see HANDOFF.md).

## Problem

AI coding agents (Claude Code, Cursor, Codex) create one git worktree per task and rarely remove them.
On one real machine, two repos held 240 worktrees taking 298 GB. None of PureMac's current categories finds them,
and a folder-name-based cleaner would be dangerous: some of those worktrees hold uncommitted or unpushed work,
and some were created minutes ago by a run that is still active.

## Non-goals

- No deletion based on folder names. Every decision goes through `git`.
- Nothing else inside `.claude`, `.cursor` or `.codex` is touched (`settings*.json`, `skills`, `rules`, sessions). See upstream #51.
- No network calls by default (no `gh`, no `git fetch`). The verdict uses only the local refs as they are.
- No Trash. Worktrees are removed with `git worktree remove`, so git metadata stays consistent, and the space really comes back.

## Discovery

1. **Roots.** Without any setup, scan these:
   - the global agent folders listed below;
   - the repos from Claude Code's project list (only the `projects` keys of `~/.claude.json`, read-only).

   The user can add folders in Settings. Suggestions are offered there but nothing is preselected. Under user roots, repos are found by walking to depth 3 or 4 and looking for a `.git` **directory**.
2. **Per repo.** Run `git -C <repo> worktree list --porcelain -z`. This gives `worktree`, `HEAD`, `branch`/`detached`, `locked [reason]` and `prunable [reason]`. The main worktree (the first entry) is never a candidate.
3. **Agent folders.** Scan these whether or not they sit under a root: `<repo>/.claude/worktrees/*`, `~/.cursor/worktrees/**`, `~/.codex/worktrees/**`. For each folder with a `.git` **file**:
   - read the `gitdir:` line;
   - follow it to `<common>/worktrees/<name>`;
   - check that the main repo lists this path.
   Not listed means an **orphan**.

## Signals (all local, all read-only)

| Signal | How | Notes |
|---|---|---|
| Tracked changes | `git status --porcelain=v2 -z --untracked-files=no` | any line counts as dirty |
| Untracked files | `git status --porcelain=v2 -z --untracked-files=all --ignored=no` | split into "artifact" (matches the CLI's `Purger.artifactNames`) and "other" |
| Ignored-only files | not a blocker | `.env` is often ignored, so ignored files named `.env*` count as "other" |
| Stash | `git stash list --format=%gd%x00%gs` | attributed when the stash subject names the worktree's branch, or the stash commit's parent is reachable from its HEAD |
| Unpushed commits | `git rev-list HEAD --not --remotes --count` | covers "no upstream configured" too |
| Merged into base | `merge-base --is-ancestor HEAD <base>`, then `git cherry <base> HEAD` (all `-`) | catches rebase merges; squash merges are not caught, so they stay 🟡 |
| Own commits | `git rev-list <base>..HEAD --count` plus `HEAD == merge-base` | **HEAD == base with no commits of its own is NOT "merged"**, it is "never used" |
| Locked | porcelain `locked` | |
| Activity | max of: worktree dir mtime, `<common>/worktrees/<name>/{HEAD,index,logs/HEAD}` mtime, newest file mtime (skipping artifact dirs, capped walk), branch tip commit date | |
| In use | a process whose cwd is inside the worktree (`proc_pidinfo` with `PROC_PIDVNODEPATHINFO`, no `lsof +D`) | |
| Size | `directorySize`, split into artifacts and the rest | |

The base branch is `origin/HEAD`, else `origin/main`, else `origin/master`. It can be overridden per repo.

## Statuses

Order matters: the first rule that matches wins.

1. 🔴 **Protected**: tracked changes, unpushed commits, an attributed stash, locked, or in use. These rows cannot be selected. The row offers "Exclude" and "Clean artifacts only".
2. ⚪ **Orphan / prunable**: git says `prunable`, or the folder is not in `worktree list`. The action is `git worktree prune` for prunable entries. For an orphan folder the row only shows the path, with no delete in v1.
3. 🟡 **Needs review**: any of these:
   - merged but active within N days;
   - untracked "other" files present;
   - no commits of its own (HEAD == base);
   - squash-merge suspected (not an ancestor, cherry not all `-`, but no unpushed commits).
   Not selected by default.
4. 🟢 **Safe to delete**: merged (ancestor or cherry all `-`), clean, nothing untracked except artifacts, no unpushed commits, no stash, inactive for ≥ N days, not locked, not in use. Selected by default.

N defaults to 7 days and can be changed in settings.

## Deletion

Done per item, in a fixed order:

1. **Re-check right before acting (TOCTOU).** Run status, lock, in-use and unpushed again. If anything changed, skip the item and report why.
2. Run `git -C <main-repo> worktree remove <path>`. **No `--force`.** If git refuses, its stderr goes into the result's errors.
3. Delete the branch only if the user enabled that option and the branch is merged: `git branch -d <branch>`. Never `-D`.
4. Run `git -C <main-repo> worktree prune` once per repo at the end.

The freed space is the measured size before removal. The item path is the worktree path. `isActionItem` stays false, so "Reveal in Finder" keeps working, but CleaningEngine sends `.gitWorktrees` to its own branch, the same way it handles `simctlRuntimeIdentifier`.

The Smart Scan "Clean All" never includes this category unless the user turns that on.

## Code layout (fits the existing patterns)

- `Models.swift`: `case gitWorktrees = "Git Worktrees"` with an icon (`arrow.triangle.branch`), a description and a color.
- `Logic/Utilities/GitWorktreeSupport.swift`: pure, testable parsing and classification (porcelain parser, status rules), like `SimulatorRuntimeSupport`.
- `Services/GitWorktreeScanner.swift`: runs git through the existing `BrewProcessRunner` with a timeout.
- `ScanEngine.scanGitWorktrees()` and `CleaningEngine.removeGitWorktree(_:)`.
- Settings: roots, N days, base branch override, "delete merged branch", "include in Smart Scan".
- Strings in all 14 `Localizable.strings`.

## Tests

The tests build temporary repos under `$TMPDIR`: a bare "origin" plus a clone plus worktrees. They do not depend on the network or on real repos.

The cases to cover:

- merged-clean, which is 🟢;
- merged-fresh, which is 🟡;
- HEAD==base, which is 🟡;
- dirty, which is 🔴;
- untracked-only "other", which is 🟡;
- untracked artifacts only, which is 🟢;
- unpushed, which is 🔴;
- stash, which is 🔴;
- locked, which is 🔴;
- rebase-merged, which is 🟢 through cherry;
- squash-merged, which is 🟡;
- prunable, which is ⚪;
- orphan folder, which is ⚪;
- a symlink inside the worktree, which is not followed;
- a path with spaces and Cyrillic characters;
- TOCTOU: a file appears between scan and clean, and the item is skipped;
- `worktree remove` refuses, and the error surfaces;
- the main worktree is never listed;
- nothing outside the worktree path changes. A snapshot of `.claude/` before and after must be identical.

## Decisions (user, 2026-10-29)

1. **Default roots.** Without any setup, scan these:
   - the global agent folders `~/.cursor/worktrees` and `~/.codex/worktrees`;
   - the repos listed in Claude Code's project list. This means only the keys of `projects` in `~/.claude.json`, read-only. Nothing else in that file is read or written.

   User-added roots come on top. No `~/Projects`-style roots are preselected.
2. **In-use detection.** Any worktree under an agent folder (`.claude/worktrees`, `~/.cursor/worktrees`, `~/.codex/worktrees`) with activity in the last 24 h is 🔴, regardless of N. The process-cwd check and git `locked` still apply to every worktree.
3. **Orphan folders.** v1 only displays them, as their own group with size and path. There is no delete action.
4. **Form.** It is a cleaning category, "Git Worktrees", under Developer Cleanup. It reuses the existing list, filters and Review removal. The repo name goes into the row title.

These decisions are still open to the maintainer's feedback on the upstream issue.
