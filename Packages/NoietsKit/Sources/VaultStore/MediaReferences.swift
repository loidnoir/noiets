import Foundation

/// Keeps media references working when notes move. `fixAfterMove` rewrites
/// `![](path)` and `![[file.ext]]` references inside moved markdown files
/// (including files inside moved folders) whose relative paths broke,
/// pointing them at the media's current vault-root-relative location.
///
/// Resolution here is deliberately STRICT — the note's folder, the vault
/// root, then `assets/<name>` — without the renderer's vault-wide filename
/// fallback, so rewritten files stay portable (HTML/PDF export, Obsidian).
public enum MediaReferences {

    public struct Reference: Equatable {
        public let pathRange: NSRange // the path/target span inside the syntax
        public let path: String
    }

    // `![](path)` — any media; the path never contains ")" or newlines.
    private static let markdownEmbed = try! NSRegularExpression(
        pattern: "!\\[[^\\]\\n]*\\]\\(([^)\\n]+)\\)")
    // `![[target]]` / `![[target|alias]]` — file embeds only (see extension
    // check below); note embeds are title-resolved and never rewritten.
    private static let wikiEmbed = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]|\\n]+)(\\|[^\\]\\n]*)?\\]\\]")

    /// Media references in `text`, in document order. Fenced code blocks are
    /// skipped; `![[Note]]` embeds without a file extension are not reported.
    public static func references(in text: String) -> [Reference] {
        let ns = text as NSString
        var refs: [Reference] = []
        var inFence = false
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = line.location + max(line.length, 1) }
            let content = ns.substring(with: line)
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            for regex in [markdownEmbed, wikiEmbed] {
                regex.enumerateMatches(in: text, range: line) { match, _, _ in
                    guard let match else { return }
                    let pathRange = match.range(at: 1)
                    let path = ns.substring(with: pathRange)
                        .trimmingCharacters(in: .whitespaces)
                    if regex === wikiEmbed, (path as NSString).pathExtension.isEmpty {
                        return // a note embed, not media
                    }
                    refs.append(Reference(pathRange: pathRange, path: path))
                }
            }
        }
        return refs.sorted { $0.pathRange.location < $1.pathRange.location }
    }

    /// First existing candidate for `path` seen from `noteFolder`: the note's
    /// own folder, the vault root, then `assets/<name>` for bare filenames.
    /// Absolute, `~`, and remote paths return nil (never rewritten).
    public static func resolve(
        _ path: String, noteFolder: URL, vault: Vault,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        let trimmed = (path.removingPercentEncoding ?? path)
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.hasPrefix("http://"), !trimmed.hasPrefix("https://")
        else { return nil }

        var candidates = [
            noteFolder.appendingPathComponent(trimmed),
            vault.rootURL.appendingPathComponent(trimmed),
        ]
        if !trimmed.contains("/") {
            candidates.append(vault.rootURL.appendingPathComponent("assets/\(trimmed)"))
        }
        return candidates.map(\.standardizedFileURL).first(where: exists)
    }

    /// Rewrites references in the moved markdown files after the moves
    /// (old → new) already happened on disk. Returns the rewritten files.
    @discardableResult
    public static func fixAfterMove(_ moves: [(from: URL, to: URL)], vault: Vault) -> [URL] {
        let fm = FileManager.default
        let pairs = moves.map { ($0.from.standardizedFileURL, $0.to.standardizedFileURL) }

        // Where a pre-move path lives now (identity for untouched paths).
        func remap(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            for (old, new) in pairs {
                if path == old.path { return new }
                if path.hasPrefix(old.path + "/") {
                    return URL(fileURLWithPath: new.path + path.dropFirst(old.path.count))
                }
            }
            return url
        }
        // A pre-move candidate "existed" iff its post-move location exists.
        func existedBeforeMove(_ url: URL) -> Bool {
            fm.fileExists(atPath: remap(url).path)
        }

        // Every moved markdown file, with its pre-move location (folder moves
        // carry their contained notes along).
        var files: [(oldURL: URL, newURL: URL)] = []
        for (old, new) in pairs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: new.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let walker = fm.enumerator(at: new, includingPropertiesForKeys: nil) else { continue }
                for case let inner as URL in walker where Vault.isMarkdownFile(inner) {
                    let suffix = inner.standardizedFileURL.path.dropFirst(new.path.count)
                    files.append((URL(fileURLWithPath: old.path + suffix),
                                  inner.standardizedFileURL))
                }
            } else if Vault.isMarkdownFile(new) {
                files.append((old, new))
            }
        }

        var rewritten: [URL] = []
        for file in files {
            guard let text = try? NoteIO.read(file.newURL) else { continue }
            let refs = references(in: text)
            guard !refs.isEmpty else { continue }
            let oldFolder = file.oldURL.deletingLastPathComponent()
            let newFolder = file.newURL.deletingLastPathComponent()

            var edits: [(NSRange, String)] = []
            for ref in refs {
                // What the reference pointed at before the move; skip
                // remote/absolute/unresolvable ones.
                guard let target = resolve(ref.path, noteFolder: oldFolder, vault: vault,
                                           exists: existedBeforeMove)
                else { continue }
                let current = remap(target)
                // Still reaches the same file from the new location? Leave it.
                if resolve(ref.path, noteFolder: newFolder, vault: vault) == current { continue }
                let newPath = vault.relativePath(of: current)
                guard !newPath.isEmpty, newPath != ref.path else { continue }
                edits.append((ref.pathRange, newPath))
            }
            guard !edits.isEmpty else { continue }

            let updated = NSMutableString(string: text)
            for (range, path) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                updated.replaceCharacters(in: range, with: path)
            }
            do {
                try NoteIO.write(updated as String, to: file.newURL)
                rewritten.append(file.newURL)
            } catch {
                continue
            }
        }
        return rewritten
    }
}
