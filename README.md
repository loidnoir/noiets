# Noiets

A local-first, native macOS markdown notes app — Obsidian's engine with Things 3's restraint.

- Plain `.md` files in a vault folder you choose; disk is the source of truth.
- Pure AppKit + TextKit 2 editor with Obsidian-style Live Preview (the caret's line reverts to raw source).
- Vim motions in the editor. Keyboard-first: ⌘O quick-open, ⌘P command palette.
- SQLite/FTS5 index (rebuildable cache in Application Support) for instant search, tags, backlinks.

## Building

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make gen     # generate Noiets.xcodeproj (gitignored)
make build   # xcodebuild Debug into ./build
make run     # build + launch
make test    # run package unit tests (MarkdownKit, VimKit, IndexKit)
```

The app code lives in `App/` (AppKit shell) and `Packages/NoietsKit/` (SwiftPM modules:
SharedModel, VaultStore, MarkdownKit, VimKit, EditorKit, RenderKit, IndexKit).

Set the `NOIETS_VAULT` environment variable to point at a vault folder (used by tests/dev
runs to bypass the first-launch vault picker).
