# FinderSearch — homy fork

This is a fork of [zeusinsight/FinderSearch](https://github.com/zeusinsight/FinderSearch)
that carries every feature of [Homy](https://tryhomy.app/) on top of the
original app, while staying trivially mergeable with upstream.

## Getting upstream updates

```bash
./scripts/sync-upstream.sh
```

That single command fetches `zeusinsight/FinderSearch`, fast-forwards the
pristine `main` branch, and merges it into the `homy` branch you work on.

| Branch | Purpose |
|---|---|
| `main` | Pristine mirror of `upstream/main` — never commit here |
| `homy` | This fork's features — the branch you build and use |

Remotes: `origin` → `oseanstudio/FinderSearch` (this fork),
`upstream` → `zeusinsight/FinderSearch`.

### Why merges stay clean

Every Homy feature lives in its own new file under `Sources/FinderSearch/`
(see the table below). Only three upstream files are touched, each at a
small marked block that starts with `// HOMY:`:

- `Model.swift` — routes the new sidebar destinations (`home`, `cat:…`,
  `smart:…`, `sources`, `dupes`, `cleanup`) and gives them titles.
- `Sidebar.swift` — inserts the Homy sidebar sections.
- `App.swift` — adds the Homy menu, the menu-bar downloads item, and the
  special-content branch in `fileContent`.

If upstream rewrites those areas, re-adding the marked block is a
two-line fix; everything else merges untouched.

## Homy feature parity

| Homy feature | Where | Shortcut |
|---|---|---|
| Home dashboard with category totals and recent shelves | `HomeDashboard.swift` | sidebar → Home |
| Shelves: Images, Videos, Music, Documents, Archives, Apps | `HomeDashboard.swift`, routes `cat:…` | sidebar |
| Smart Folders (Large Files, Screenshots) | `SmartFolders.swift`, routes `smart:…` | sidebar |
| Pinned folders | upstream Favorites (unchanged) | sidebar |
| Grid/list views, sorting, resizable cards | upstream views | ⌘1–⌘4 |
| Quick Look previews | upstream | Space |
| Built-in music player | `MusicPlayer.swift` | ⌃⌘P, ⌘←/⌘→ |
| Inspector (dimensions, duration, camera, download source) | `HomyInspector.swift` | ⌥⌘I |
| Natural-language search with editable filter chips | `NaturalLanguage.swift` | ⌘F |
| Search text inside files | fsearch `grep:` filter | add `grep:` or toggle in chips |
| Saved searches pinned to the sidebar | `SavedSearches.swift` | ⌘S while searching |
| Text in images (OCR) | `TextRecognition.swift` (Vision) | ⇧⌘C |
| Downloaded From — downloads grouped by source | `WhereFroms.swift` | ⇧⌘J |
| Duplicates (identical SHA-256 + look-alike photos) | `Duplicates.swift` | ⇧⌘D |
| Clean Up (old installers, downloads, screenshots, big videos) | `Cleanup.swift` | ⇧⌘K |
| Quick Search from any app, Spotlight-style | `QuickSearch.swift` | ⇧⌘Space (global) |
| Menu-bar list of latest downloads | `MenuBarDownloads.swift` | menu bar |
| Playful / Minimal themes | `HomyTheme.swift` | ⌃⌘T |
| Shortcuts actions (Find Files, Get Latest Download, Search in Homy) | `HomyIntents.swift` | Shortcuts.app |
| Trash-first deletion everywhere | upstream + our tools | ⌫ |

Everything runs locally; the fsearch engine, Vision OCR, and file hashing
never leave your machine.

Not carried over from Homy: paid licensing/activation (this fork is free,
MIT), Sparkle-style auto-updates (rebuild with `./scripts/build.sh`), and
the macOS 26-only multi-file drag stack (the system provides it).

## Build

```bash
./scripts/build.sh && open dist/FinderSearch.app
```

The global ⇧⌘Space Quick Search hotkey needs the app running once from
`dist/FinderSearch.app` (Launch Services registration). Full Disk Access
is recommended, as with upstream.
