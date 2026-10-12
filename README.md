# Noiets

A local-first, native macOS markdown notes app — Obsidian's engine with Things 3's restraint.
Pure AppKit + TextKit 2, no web views, no Electron.

- Plain `.md` files in a vault folder you own. Disk is the source of truth; the app just watches it.
- **Resume**: reopening the app restores the last-open note for each vault. In-app moves/renames
  keep it remembered; unavailable notes fall back to the first note. Stored locally in app preferences.
- **Live Preview**: markup hides on inactive lines and the caret's line reverts to raw source —
  exactly the Obsidian editing model, built natively on TextKit 2 custom layout fragments.
- **Vim** in the editor: Normal/Insert/Visual, counts, operators (`d c y`), text objects
  (`iw a" i( ip it`), `f/t`, `%`, `{ }`, `/` search, `.` repeat, one undo step per command.
- **Rich blocks**: syntax-highlighted code fences, inline images, LaTeX math (SwiftMath),
  real table grids — all reverting to source when the caret enters.
- **Linked notes**: `[[wiki links]]` with autocompletion and create-on-missing, backlinks +
  outline in a toggleable right panel, `#tags`.
- **Instant retrieval**: SQLite FTS5 index (a rebuildable cache in Application Support — never
  in your vault), kept live by FSEvents.

## Keyboard

| | |
|---|---|
| ⌘O | Quick-open saved views (first) and notes |
| ⌘P | Command palette (type `#` to browse tags) |
| ⇧⌘F | Search the vault |
| ⌘N / ⇧⌘N | New note / folder |
| ⌘0 / ⌥⌘0 | Toggle sidebar / backlinks panel |
| ⇧⌘E | Export note as HTML |
| ⌘⌫ | Move note to trash (vault-local `.trash`, Obsidian-compatible) |
| Esc | Vim normal mode |

## Install

Download the latest `Noiets-x.y.z.dmg` from
[Releases](https://github.com/loidnoir/noites/releases/latest), open it, and drag
**Noiets** into **Applications**.

Unless the release is Developer ID signed and notarized, macOS Gatekeeper will block the
first launch: open **System Settings → Privacy & Security**, scroll to the message about
Noiets, and click **Open Anyway** (needed once).

Updates are automatic (Sparkle): the app checks the release feed in the background and
offers new versions in place — or use **Noiets → Check for Updates…** any time.

## Releasing (maintainers)

Releases are built by [`release.yml`](.github/workflows/release.yml) when a version tag
is pushed:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The workflow runs the package tests, builds Release, packages a DMG, generates a signed
Sparkle `appcast.xml`, and publishes both as a GitHub release. The app's update feed is
`releases/latest/download/appcast.xml`, so shipping a release *is* shipping the update.

Required repo secret: `SPARKLE_PRIVATE_KEY` — the Sparkle EdDSA private key
(base64 line, generated once; the matching public key is in `project.yml` as
`SUPublicEDKey`). Losing it means existing installs can't verify future updates.

Optional secrets for a signed + notarized app (no Gatekeeper friction):
`MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`,
`APPLE_APP_PASSWORD`.

## Building

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make gen     # generate Noiets.xcodeproj (gitignored)
make build   # xcodebuild Debug into ./build
make run     # build + launch
make test    # package unit tests (103 tests: markdown, vim, index, export)
```

Code layout: `App/` (AppKit shell) and `Packages/NoietsKit/` with strict downward deps —
`SharedModel` ← `VaultStore`/`MarkdownKit`/`VimKit`(headless) ← `RenderKit`/`IndexKit` ← `EditorKit`.

## Search and saved views

The sidebar's single **Search** page supports full-text words and filters such as `tag:work`, `sort:title`, and `layout:month`. Its syntax suggestions use the same popup as tag completion: arrows select, Return/Tab completes the current token, and Esc dismisses it. **Save** (`⌘⏎`) stores a named query. Saved views lead matching documents in **⌘O**, with accent-colored folder icons and names; their context menu contains only query rename/delete actions, never file or folder creation.

## PDF export

**File → Export PDF…** creates a paginated, white, print-friendly document using the editor's font hierarchy, spacing, accent-colored list markers, Libron quotes, and monospaced code. Images in `![](path)` and `![[image.png]]` references are embedded into the PDF, including note-relative paths and vault attachment filename lookup. Remote HTTP(S) images are downloaded before printing; unavailable images get a visible placeholder. Printing waits for images, fonts, and Mermaid diagrams to finish loading rather than silently omitting them. Notes and editor state are unchanged.

## Glass content background

Open the command search with **⌘P**, then search **glass**, **blur**, or **transparency** and choose **Toggle transparency**. It toggles one blurred, translucent backdrop across the entire right-hand content pane: notes, Search, saved Views, Trash, and images. Text and the sidebar retain full opacity. Fresh installs start with transparency enabled at **85% background opacity / blur radius 12**. Existing saved choices take precedence. Transparency, opacity, and blur radius are saved in device-local app preferences and restored across restarts and projects. Native fullscreen and macOS **Reduce Transparency** temporarily make the content pane opaque without changing the saved settings.

## Dev harness

For live, session-only theme experiments, quit the running app first:

```bash
make run ARGS=--debug-theme
```

The floating Theme Colors panel offers color wells and hex fields (`#RRGGBB` / `#RRGGBBAA`), plus **Background opacity** and **Blur radius** (0–100) sliders. Moving either slider enables transparency for live preview; radius 0 removes blur, while 100% opacity makes the content pane opaque. The panel reports the active backend.

Blur uses the same private WindowServer `CGSSetWindowBackgroundBlurRadius` path as Ghostty, without AppKit material tint on that path. Symbols are dynamically resolved; missing/rejected API calls use an AppKit material fallback, which cannot honor the requested radius. The backdrop stays stable across page changes; blur is cleared on disable, fullscreen, and window close. **This private API is not App Store-safe and may change across macOS releases.** Reduce Transparency disables the sliders and keeps the content pane opaque.

Colors affect the current light/dark appearance without forcing an appearance. **Reset All** restores colors and backdrop defaults; **Copy Palette** includes both color palettes and the `editorBackdrop` values as JSON, ready to share. Reopen the panel via **Window → Theme Colors…**. Color experiments are never written to preferences or note files; a normal launch uses the original color theme. Backdrop settings are saved separately and restored on launch.

Environment hooks used by the automated verify loop (all inert in normal runs):

- `NOIETS_VAULT=<path>` — use this vault, skip the picker
- `NOIETS_SELFTEST=1` (+`_DELAY`) — print a JSON diagnostic of live app state and exit:
  TextKit 2 status, live-preview toggling, vim commands through real key events, index
  queries, palette, wiki create-on-missing/completion
- `NOIETS_PERF=1` — adds typing-latency + search-latency measurements
- `NOIETS_SNAPSHOT=<png>` — self-screenshot; `NOIETS_OPEN` / `NOIETS_SCROLL_TO` — navigate
- `NOIETS_SHOW_INSPECTOR=1` — open the right panel at launch

## TextKit 2 guardrails

macOS 26's NSTextView silently downgrades to TextKit 1 if anything touches `.layoutManager`,
destroying custom fragments. Noiets registers `NSTextViewAllowsDowngradeToLayoutManager=NO`,
never references `.layoutManager`, and asserts `textLayoutManager != nil` at runtime.
Grep-gate before committing: `grep -rn "\.layoutManager" App Packages/NoietsKit/Sources` → no hits.
