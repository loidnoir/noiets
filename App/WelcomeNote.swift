/// The note seeded into an empty vault. Doubles as a manual test fixture — it
/// exercises every markdown feature the editor will grow through M1–M6.
enum WelcomeNote {
    static let markdown = #"""
    ---
    title: Welcome to Noiets
    tags: [welcome]
    ---

    # Welcome to Noiets

    Your notes are plain Markdown files in a folder you own. Local-first,
    portable, Obsidian-compatible.

    **Bold**, *italic*, ***both***, ~~struck~~, ==highlighted==, and `inline code`.

    ## Links

    A [markdown link](https://example.com), a wiki link to [[Second Note]],
    and one with an alias: [[Second Note|that same note]].

    Tags work anywhere: #welcome #docs/setup

    ## Lists

    - A bullet
    - Another bullet
        - Nested
    - [ ] An open task
    - [x] A done task

    1. First
    2. Second

    > A quote to set the mood.

    ## Code

    ```swift
    let greeting = "Hello, Noiets"
    print(greeting)
    ```

    ## Math

    Inline math like $e^{i\pi} + 1 = 0$ and display math:

    $$\int_0^1 x^2 \, dx = \frac{1}{3}$$

    ## Table

    | Feature      | Status |
    | ------------ | ------ |
    | Live preview | soon   |
    | Vim motions  | soon   |

    ---

    Press `⌘O` to switch notes, `⌘P` for the command palette. Happy writing.
    """#
}
