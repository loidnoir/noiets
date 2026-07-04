# Noiets

Local-first markdown notes. Your project is a plain folder of `.md` files — portable,
git-friendly, Obsidian-compatible. The app never locks anything in: the search index is a
rebuildable cache, and everything you create is a file you own.

This page is the whole manual. Open it any time with `⌘P → Open Docs`.

---

## The window

Two panes: the **sidebar** (Search / Views / Trash, your saved views, the folder tree) and
the **content pane** (editor, lists, or an image). A right panel with backlinks and the
outline toggles with `⌥⌘0`.

Move between panes like vim splits:

| Keys | Action |
| --- | --- |
| `⌃h` | focus the sidebar tree |
| `⌃l` (or `Esc` in the tree) | back to the content pane |

The bar at the sidebar's bottom always shows where keys go: `NORMAL / INSERT / VISUAL`
for the editor, `TREE` or `LIST` elsewhere — plus search counts and pending keys.

## Global shortcuts

| Keys | Action |
| --- | --- |
| `⌘O` | quick-open notes by name |
| `⌘P` | command palette (type `#` to browse tags) |
| `⇧⌘F` | search the project |
| `⌘N` / `⇧⌘N` | new note / new folder |
| `⌘S` | toggle the sidebar |
| `⌥⌘0` | toggle backlinks + outline panel |
| `⌘L` | lock / unlock the note |
| `⇧⌘E` | export the note as HTML |
| `⌥⌘R` | reveal the note in Finder |

## Editing (vim)

The editor is modal: `Esc` for normal mode, `i a I A o O` into insert. Arrow keys act as
`h j k l` in normal mode; `j`/`k` move by rendered (wrapped) lines with a sticky column.

- **Motions** — `h j k l w b e 0 ^ $ gg G f t ; , { } %`, counts (`3w`), `⌃d`/`⌃u` half-page
- **Operators** — `d c y` with motions and text objects (`iw aw i" a" i( ip it`), `dd cc yy`,
  `D C`, `x r ~ J`, `p P`, `u` / `⌃r` undo/redo (one undo step per command), `.` repeat
- **Selection** — `v` character-wise, `V` line-wise; `x` or `d` delete the selection,
  `Tab` / `⇧Tab` indent or dedent the selected lines
- **Search** — `/text` then `n`/`N`; `*` / `#` jump to the word under the caret; the mode
  bar shows `3/10` match position
- **Go to line** — `:` then a number; line numbers appear while `:` is open
- **Clipboard** — everything that yanks or deletes (`y yy d dd D x c`) also lands on the
  system clipboard; `⌘C ⌘V` work as usual and copy raw markdown

## Writing markdown

Markup renders in place; the caret's line reverts to raw source (Obsidian's Live Preview
model). Copying always yields raw markdown.

- **Blocks** — headings, quotes (bar + muted text), rules, bullet/numbered/task lists
  (round bullets; check circles for tasks), tables (real grids), fenced code with syntax
  highlighting (the fence shows just the language until the caret enters)
- **Math** — inline `$x$`, display `$$…$$` on a line, or multi-line `$$` blocks — all
  typeset natively
- **Images** — `![](path)` and `![[image.png]]` render inline; paste an image to embed it
  (saved into `assets/`); double-click to open it in the content pane
- **Links** — `[[wiki links]]` autocomplete as you type `[[`, create the note on click if
  missing; `#tags` are clickable; URLs open in the browser
- **Frontmatter** — a leading `---` block is preserved byte-for-byte; its `key: value`
  properties (scalars, `[a, b]` lists) power views (below); `tags:` merges with inline tags

## Locked notes

`⌘L` locks the open note: it renders fully — the caret's line never reverts to raw
markup — and every edit is rejected, while navigation and copying keep working. The mode
bar shows `LOCKED`. `⌘L` again unlocks. Locks live in the project's own database, so they
survive reinstalls and travel with the folder. This very docs page is permanently locked.

## Views

Views replace bookmarks, recents, and smart folders with one idea: **a saved query**.
Open **Views** in the sidebar and type filter tokens; results update live:

```
tag:project folder:Work draft status:done modified:<7d sort:-title limit:50
```

| Token | Meaning |
| --- | --- |
| `word` or `text:word` | full-text match |
| `title:word` | title contains |
| `tag:x` | has tag (repeat to AND) |
| `folder:Work` | inside that folder |
| `modified:<7d` / `created:>2026-01-01` | date windows (`<` newer, `>` older) |
| `status:done` | frontmatter property equals; `status:*` = has it |
| `sort:modified·created·title·words` | order (`-` prefix = ascending) |
| `limit:N` | cap results |

When the query differs from what's saved, a **Save** button appears (`⌘⏎`). Saved views
are rows in the sidebar — `Enter` opens, `r` renames, `dd` deletes (notes are untouched).
Definitions live in `.noiets/views.json` inside your project, so they sync with it.

## Sidebar tree

nvim-tree style: `j k` move, counts work, `gg G` jump, `Enter`/`l` opens (folders toggle),
`h` collapses, `a` new note, `A` new folder, `r` rename, `m` move via picker, `dd` trash
(with confirmation), `v` selects multiple files — then `dd`, `m`, or `r` (renames as
`name-1, name-2, …`). Drag & drop reorders too. Images appear in the tree and open in the
content pane.

## Search, Trash, lists

All lists speak the same keys: `j k gg G` with counts, `Enter` opens, `dd` acts
(trash / delete permanently), `/` focuses the query field, `Esc` stays in the list,
`⌃h` returns to the tree.

**Trash** is the project-local `.trash` folder (Obsidian-compatible). Restore puts an item
back into the folder it came from; if that folder is gone, it lands in the project root.

## Files on disk

| Path | What |
| --- | --- |
| `*.md` | your notes — the only source of truth |
| `assets/` | pasted images |
| `.trash/` | trashed items (+ restore origins) |
| `.noiets/views.json` | saved views |
| `.noiets/index.sqlite` | search index + note locks (stays with the project) |

Updates install themselves (Sparkle): the app checks releases in the background, or use
**Noiets → Check for Updates…**.
