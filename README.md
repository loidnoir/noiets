# Noiets

A local-first, native macOS markdown notes app — Obsidian's engine with Things 3's restraint.
Pure AppKit + TextKit 2, no web views, no Electron.

- Plain `.md` files in a vault folder you own. Disk is the source of truth; the app just watches it.
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
| ⌘O | Quick-open notes |
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

## Dev harness

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
