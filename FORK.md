# Hearth — a FinderSearch fork

Hearth is this fork's identity: a home for your files with search built
in. It is a fork of [zeusinsight/FinderSearch](https://github.com/zeusinsight/FinderSearch)
carrying every feature of [Home](https://TRYHOME-URL-PLACEHOLDER/) on top of the
original app, while staying trivially mergeable with upstream. The app
ships as `dist/Hearth.app`; internal module and engine names keep their
upstream `FinderSearch` spelling so merges stay small.

## Getting upstream updates

```bash
./scripts/sync-upstream.sh
```

That single command fetches `zeusinsight/FinderSearch`, fast-forwards the
pristine `main` branch, and merges it into the `home` branch you work on.

| Branch | Purpose |
|---|---|
| `main` | Pristine mirror of `upstream/main` — never commit here |
| `home` | This fork's features — the branch you build and use |

Remotes: `origin` → `oseanstudio/FinderSearch` (this fork),
`upstream` → `zeusinsight/FinderSearch`.

### Why merges stay clean

Every Home feature lives in its own new file under `Sources/FinderSearch/`
(see the table below). Only three upstream files are touched, each at a
small marked block that starts with `// HOME:`:

- `Model.swift` — routes the new sidebar destinations (`home`, `cat:…`,
  `smart:…`, `sources`, `dupes`, `cleanup`) and gives them titles.
- `Sidebar.swift` — inserts the Home sidebar sections.
- `App.swift` — adds the Home menu, the menu-bar downloads item, and the
  special-content branch in `fileContent`.

If upstream rewrites those areas, re-adding the marked block is a
two-line fix; everything else merges untouched.

## Home feature parity

| Home feature | Where | Shortcut |
|---|---|---|
| Home dashboard with category totals and recent shelves | `HomeDashboard.swift` | sidebar → Home |
| Shelves: Images, Videos, Music, Documents, Archives, Apps | `HomeDashboard.swift`, routes `cat:…` | sidebar |
| Smart Folders (Large Files, Screenshots) | `HomeCore.swift`, routes `smart:…` | sidebar |
| Pinned folders | upstream Favorites (unchanged) | sidebar |
| Grid/list views, sorting, resizable cards | upstream views | ⌘1–⌘4 |
| Quick Look previews | upstream | Space |
| Built-in music player | `MusicPlayer.swift` | ⌃⌘P, ⌘←/⌘→ |
| Inspector (dimensions, duration, camera, download source) | `HomePanels.swift` | ⌥⌘I |
| Natural-language search with editable filter chips | `NaturalLanguage.swift` | ⌘F |
| Search text inside files | fsearch `grep:` filter | add `grep:` or toggle in chips |
| Saved searches pinned to the sidebar | `NaturalLanguage.swift` | ⌘S while searching |
| Text in images (OCR) | `TextRecognition.swift` (Vision) | ⇧⌘C |
| Downloaded From — downloads grouped by source | `WhereFroms.swift` | ⇧⌘J |
| Duplicates (identical SHA-256 + look-alike photos) | `Duplicates.swift` | ⇧⌘D |
| Clean Up (old installers, downloads, screenshots, big videos) | `Cleanup.swift` | ⇧⌘K |
| Quick Search from any app, Spotlight-style | `QuickSearch.swift` | ⇧⌘Space (global) |
| **Search** — semantic search inside files via [DigUp](https://github.com/ARahim3/DigUp) | `DigUpBridge.swift`, `DigUpSemantic.swift` | ⇧⌘F, sidebar |
| **Update Center** — alerts + one-click installs for FinderSearch and DigUp releases | `UpdateCenter.swift` | Home menu, toolbar bell |
| Menu-bar quick search — the menu-bar icon opens a search bar (live results, ↩ opens top hit) plus latest download, free disk space and Quick Search/Updates shortcuts | `MenuBarDownloads.swift` | menu bar |
| Playful / Minimal themes | `HomeTheme.swift` | ⌃⌘T |
| Quick Look previews in their own resizable window — scroll-wheel zoom at the cursor, middle-drag or drag pan, double-click fits | `QuickLookWindow.swift` | Space |
| **Custom collections** — named folder groups ("Work" = ~/Projects + ~/Invoices) as a reorderable sidebar section, Home shelves, searchable like categories; create with the sidebar's New Collection… row, manage via right-click | `CollectionsAndRules.swift` | sidebar |
| **Custom smart folders** — rule builder (kind, size, age, name contains, downloaded from) persisted alongside the built-ins; edit/delete via right-click | `CollectionsAndRules.swift` | sidebar |
| **Open at the matched spot** — Search results open PDFs at the matched page and video/audio at the matched moment in their own window | `SpotPreview.swift` | double-click |
| **Big Folders space map** — per-folder size bars with drill-down inside Clean Up | `SpaceMap.swift` | Clean Up |
| **Finder-style sidebar customization** — drag a section title and it lifts, follows the cursor with an insertion line, and drops into place; right-click any section, row or built-in (Home, Recents, Categories, Smart Folders, Tags, iCloud…) → Remove from Sidebar; **Customize Sidebar…** (right-click or Hearth menu) restores anything, and Reset starts over. Layout persists. | `Sidebar.swift` | drag / right-click |
| **Category-scoped search** — while on an Images/Videos/Documents/… route, the search bar filters within that category | `Model.swift`, `HomeCore.swift` | ⌘F |
| **Type-select** — typing jumps to filenames by prefix, cycling on repeats | `Model.swift`, `App.swift` | just type |
| Shortcuts actions (Find Files, Get Latest Download, Search in Home) | `HomeIntents.swift` | Shortcuts.app |
| Trash-first deletion everywhere | upstream + our tools | ⌫ |

Everything runs locally; the fsearch engine, Vision OCR, and file hashing
never leave your machine.

Not carried over from Home: paid licensing/activation (this fork is free,
MIT), Sparkle-style auto-updates (rebuild with `./scripts/build.sh`), and
the macOS 26-only multi-file drag stack (the system provides it).

## DigUp integration (Search)

[DigUp](https://github.com/ARahim3/DigUp) adds search by what is inside
files — photo scenes, PDF and document text, what is said in recordings —
with EmbeddingGemma 2 running fully on-device. The sidebar's **Describe
Contents** row (⇧⌘F) hosts it.

The integration talks only to DigUp's documented CLI surfaces, so DigUp
releases keep working without changes here:

- `digup search-service` (JSON lines) — live search with a warm encoder,
  from `DigUpBridge.swift`.
- `digup index-service` (JSON lines) — the Sync Now button's indexer, with
  per-file progress.
- `digup download-model` (JSON lines) — only offered when the model folder
  has no weights; the command itself skips files already present.

Reuse rules (what you asked for):

- If DigUp.app is installed, its CLI is used in place
  (`DigUp.app/Contents/Helpers/digup`, or `digup` on PATH, or `DIGUP_CLI`).
- The model (`~/Library/Application Support/DigUp/Models`) is never
  re-downloaded, and the index (`~/Library/Application Support/DigUp/
  index.noindex`) is never rebuilt — the same files DigUp.app owns.
- The folder list merges DigUp's own choices (its defaults domain
  `com.abdurrahim.DigUp`, key `roots`) with folders added in the fork's
  Manage Folders sheet.

## Update Center

The fork checks GitHub every six hours (and on launch) for:

- **zeusinsight/FinderSearch** releases — a toolbar bell shows the count;
  **Install** merges upstream `main` into `home` via
  `scripts/sync-upstream.sh` and rebuilds with `scripts/build.sh`. Your
  features live in fork-only files with `// HOME:`-marked integration
  points, so the merge keeps them; a **Relaunch** button finishes the job.
  `scripts/build.sh` writes the checkout path into the app bundle
  (`Contents/Resources/repo-root`) so the rebuild can find the repo.
- **ARahim3/DigUp** releases (only when DigUp is installed) — **Install**
  upgrades the brew cask when brew manages it, otherwise downloads the
  release DMG into /Applications. Model and index are untouched by both.

Alerts appear as the toolbar badge, a Home-menu item, and (when the app is
in the background) a system notification. Manual check: Home → Check for
Updates…

## Build

```bash
./scripts/build.sh && open dist/Hearth.app
```

The global ⇧⌘Space Quick Search hotkey needs the app running once from
`dist/Hearth.app` (Launch Services registration). Full Disk Access
is recommended, as with upstream.
