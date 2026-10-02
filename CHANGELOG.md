# Changelog

All notable changes to this project; versions follow SemVer. From `[Unreleased]` on, the format follows Keep a Changelog. The sections below it are the release notes as published on GitHub, with their headings moved one level down and the em dash written as a colon.

## [Unreleased]

## [2.1.0] - 2026-10-02

### Added

- A buffer whose filetype is dotted with a `markdown` part, such as `rzk.markdown` for a literate file, previews whole as Markdown with no config, since Neovim reads a dotted filetype as each of its parts in turn; before, only the filetype `markdown` did. Thanks @ddxtanx (#32).
- `filetypes` option: filetypes with no `markdown` part, such as `{ "quarto", "rmd" }`, preview whole as Markdown too. The list adds to `markdown` and never replaces it. A value that is not a list of filetype names is refused by `setup()` with one error, `mdkite: filetypes takes a list of filetype names, such as { "quarto" }; setup changed nothing`, and that call applies nothing. Thanks @ddxtanx (#32).

## [2.0.0] - 2026-10-02

### Upgrading from markdown-preview.nvim

The plugin is mdkite.nvim from this release, and the server it runs on is kitehost.nvim, live-server.nvim's name from its v2.0.0, which this release requires. Through 2.x the former lazy.nvim spec still installs it, since GitHub redirects the repository's former name; the former module and commands still work, each warning once a session and naming its replacement, and the former opt-out global still opts out. All three are removed in 3.0.0. Everything else in the table takes the new name now.

| What | Before 2.0.0 | From 2.0.0 |
| --- | --- | --- |
| Repository and lazy.nvim spec | `selimacerbas/markdown-preview.nvim` | `selimacerbas/mdkite.nvim` |
| Server dependency | `selimacerbas/live-server.nvim` | `selimacerbas/kitehost.nvim`, v2.0.0 or newer |
| Module | `require("markdown_preview")` | `require("mdkite")` |
| Commands | `:MarkdownPreview`, `:MarkdownPreviewRefresh`, `:MarkdownPreviewStop` | `:MdKite` with `start`, `refresh` and `stop`, one for each former command in that order, and the new `toggle`, completed by `<Tab>`, none taking an argument; a bare `:MdKite` runs `start` |
| Notices | `Markdown Preview: ...` | `mdkite: ...` on every notice this plugin makes (the server's own notices begin `kitehost:`), but a deprecation warning, which is Neovim's own text (`:MarkdownPreview is deprecated, use :MdKite start instead.`) |
| Cache directory | `stdpath("cache")/markdown-preview` | `stdpath("cache")/mdkite` |
| Opt-out global | `vim.g.loaded_markdown_preview` | `vim.g.loaded_mdkite`; the former one still opts out |
| Auto-refresh augroup | `MarkdownPreviewAuto` | `MdKiteAuto` |
| Browser console prefix | `[markdown-preview]` | `[mdkite]` |
| Page title | `Markdown Preview` | `mdkite` |

In takeover mode, a preview of a release before 2.0.0 still running in another Neovim keeps its lock under the former cache directory: a start names it and its port in one error, starts nothing beside it and writes nothing under that directory.

A lazy.nvim spec that relies on `opts` or `config = true` and is named after neither repository (a `name` or `dir` of its own, or a fork under another name) sets `main = "mdkite"`: two top-level modules ship through 2.x, `mdkite` and `markdown_preview`, so lazy.nvim cannot choose the one its `opts` go to and reports `Lua module not found for config of <name>`. The new spec, the former one, a fork that keeps the name mdkite.nvim and a spec with its own `config` function need none.

### Added

- `lazy.lua`: lazy.nvim installs kitehost.nvim from this plugin's own declaration, so a spec with no `dependencies` line still gets it.
- `:MdKite toggle` starts the preview, or stops the one running, a joined one included.

### Changed

- **BREAKING:** The plugin runs on kitehost.nvim v2.0.0 or newer (the upgrading section above). With an older server on the runtimepath, or none, a start refuses with one error, `mdkite: requires kitehost.nvim v2.0.0 or newer; install or update selimacerbas/kitehost.nvim`, where a missing server raised a Lua error as the plugin loaded. Each start looks for the server again until it finds one, so one put on the runtimepath after the plugin loaded is used.
- A kitehost.nvim without a capability the plugin requires, `server.features.host_check` (the Host check that keeps a DNS-rebinding page from the token the loopback page carries) or `server.features.start_raises`, is refused at start the same way, with one error naming the floor and the flag it lacks, `mdkite: requires kitehost.nvim v2.0.0 or newer, and the installed one lacks features.host_check; update selimacerbas/kitehost.nvim`, where a server without the asset route was only warned about.
- The start-failure notification reads `mdkite: failed to start server (port <port>): <reason>`.
- `vim.uv` replaces the deprecated `vim.loop` throughout.
- When the port is taken by another program, the start-failure notification says so and how to pick another: `mdkite: port <port> is in use by another program. Set port to a free one in setup(), or port = 0 with instance_mode = "multi" for an OS-assigned port.` A port the OS assigns keeps the generic notification, whose reason names the port.
- When the server binds `127.0.0.1` (the default `host`, and what `"localhost"` binds), the preview URL no longer carries the `?t=` token; a server bound to any other address keeps it. The address the server bound decides, not the `host` setting: `"localhost"` opens `http://127.0.0.1:<port>/`, since a browser tries `localhost`'s `::1` first, and a takeover secondary follows the address the primary's lock records. The URL is what lands in browser history, its sync and the process list, so the token stays out of all three.

### Removed

- **BREAKING:** Neovim 0.9, which the README listed as supported. Every release since v1.0.0 needed Neovim 0.10 and failed at first use on 0.9; the requirement is now checked at load, so on 0.9 the plugin shows one notification, "mdkite: requires Neovim 0.10 or newer", and every command refuses with the same message.
- The unreferenced 7 MB demo gif, so a fresh checkout is smaller.

### Fixed

- A takeover-mode lock file that cannot be made private fails the start with the start-failure notification; before, the server stayed running with an empty lock and the start raised a Lua error.
- A preview that fails to start (a taken port, an address kitehost cannot bind, a lock file that cannot be made private) keeps no autocmds, no session token and no workspace pointer, and drops a takeover role it held as a secondary; before, six autocmds kept refreshing a preview that did not exist.
- When kitehost refuses to switch the preview to another buffer, the notice reads `mdkite: could not retarget: <reason>` and the preview keeps showing the buffer it showed, its text and images included. When the server reports file watching off after a switch, a warning says that changes made outside this editor may not refresh the preview. A reload or scroll update kitehost refuses is reported once per preview server. Before, all three went unreported.
- An IPv6 `host` such as `"::1"`, with `instance_mode = "multi"`, gives a preview URL in brackets, `http://[::1]:<port>/?t=<token>`, which browsers open; the token stays, since only a `127.0.0.1` bind's page carries it. The IPv6 wildcard `"::"`, however it is spelled, shows `http://[::1]:<port>/?t=<token>`, as kitehost.nvim does, and an IPv4-mapped address such as `"::ffff:127.0.0.1"` shows its IPv4 form.
- When a second Neovim fails to start a takeover preview on the port another Neovim's preview holds (its check for the running preview timed out, say), the running preview keeps serving its own buffer and keeps its lock file, and the notification adds that another Neovim's preview may hold the port; before, the second instance overwrote the preview's files with its own buffer and a token the server refuses, and removed the lock.
- A takeover start joins another Neovim's preview only while the process its lock names runs and the server on the lock's port takes the lock's token and refuses a request without one; before, anything listening on that port counted, so a start could join a crashed preview's lock whose port another program had since taken and send that program its scroll updates, token included.
- A session token that cannot be made fails the start with one error notification, before any server starts. A failure after the preview server started (the preview's files, the lock file, an `auto_refresh_events` entry Neovim does not know) stops the server and shows one error notification with the reason and no Lua source position; before, the server kept running and the start raised a Lua error. The same holds when joining another Neovim's preview, when the workspace directory cannot be created, and when switching buffers, where a failed switch returns the preview to the buffer it showed. A write that fails no longer empties the file the preview serves, and a lock file whose port is not a valid port is treated as absent.
- Changing `host` with `setup()` while a preview runs no longer makes the next `:MdKite start` on another buffer refuse; the new host applies to the next start.
- A Neovim that joined another's takeover preview reports a scroll update the running preview refuses (after a restart with a new token) or cannot receive (the preview is gone) once, and again after `:MdKite start` joins anew; before, it said nothing.
- Stopping the preview within 200 ms of starting it or switching buffers no longer raises a Lua error from the pending browser open, and no browser opens for the stopped preview.
- On Windows, when the runtimepath lists no copy of the preview page the plugin ships, a start finds it from the plugin's own path whichever slash that path is written with; before, a path written with forward slashes failed the start with `Could not locate assets/index.html in runtimepath`.

### Security

- The takeover-mode lock file is made private (mode 0600) on the open file before the session token is written to it, whatever the file was before; the open's own mode applies only to a file it creates. No released version left the token readable by others: a start has removed the lock before every write since the token joined it in v1.8.0, and the 0644 lock files of v1.7.0 and earlier held no token. The loopback preview page still carries the token (SECURITY.md).

## [1.10.0] - 2026-07-07

### Features
- **Relative images**: `![](pic.png)` next to your markdown file now renders in the preview, via a token-gated asset route resolved against the source file's directory (#17). Requires live-server.nvim v1.5.0+.
- **Network access**: new `host` option (default `127.0.0.1`); set `"0.0.0.0"` to view the preview from another machine, e.g. over SSH. Thanks @icyveins7 (#28, #30).
- **Custom CSS**: new `custom_css` option layers your stylesheet over the bundled styles (supports `~` and `$VAR`). Thanks @y2w8 (#21).
- **YAML front matter**: shown in a collapsible panel and stripped from the render by default; configurable via `yaml_mode` (`"panel"` / `"hide"` / `"raw"`). Closes #18. Based on work by @Al3cLee (#20).
- **`allow_raw_html` option**: set `false` to render embedded HTML as plain text when previewing untrusted markdown (#27).
- **WSL**: browser launch now tries `wslview` → `explorer.exe` → `powershell.exe`, and surfaces the preview URL if none work (#26).

### Fixes
- **Task-list checkboxes** now render (the plugin was loaded under the wrong global name). Thanks @tcuthbert (#25).
- **Preview no longer gets stuck on "Waiting for content…"** after a Neovim restart: the token placeholder collided with a JS sentinel and broke auth on tab reuse (#31).
- **Code-block language badge and copy button** stay pinned while scrolling wide code, and no longer reset scroll position on live updates. Based on work by @Al3cLee (#20).
- **Mermaid diagrams fit one page when printing** to PDF. Thanks @harish2704 (#29).

### Security
- Removed a stale `cors = true` that emitted `Access-Control-Allow-Origin: *`, which could let any website read the auth token cross-origin.
- On a non-loopback `host`, the token is no longer baked into the served page and the preview page itself is token-gated (the browser bootstraps from the `?t=` URL).
- New **Security** section in the README covering the token model, raw-HTML trade-off, CDN loading, and network-bind exposure.

**Note:** relative-image support needs live-server.nvim **v1.5.0+**; the plugin warns once if the installed version is older.

## [1.9.0] - 2026-05-24

- **Feature:** Lifecycle hooks via `setup({ hooks = { on_start = fn, on_stop = fn } })`. `on_start(url)` runs after the preview is ready and receives the full URL (with the auth token included), useful when `open_browser = false`. `on_stop()` runs after the server stops and cleanup completes. Both default to `nil`. (#24, thanks @gogongxt)

## [1.8.0] - 2026-05-24

- **Feature:** `default_theme = "dark" | "light"` config option to set the initial preview theme. The in-browser sun/moon toggle still works after page load. Closes #19. (#16, thanks @gogongxt)
- **Feature:** `mermaid_elk = true` enables the [ELK layout engine](https://github.com/mermaid-js/layout-elk) for mermaid diagrams, producing cleaner layouts for medium and large flowcharts and class diagrams. Off by default (adds ~800 KB CDN fetch). Enable per-diagram with `%%{init: {"layout": "elk"}}%%`. (#22, thanks @fuzzybear3)
- **Security:** Token auth on `content.md` and the live-reload control endpoints. A 128-bit token is generated at server start, threaded through the auto-opened browser URL, and stashed in `sessionStorage`. No user-facing config needed. (#23)
- **Requires:** `live-server.nvim` `v1.4.0+` for the token auth feature. If you pin versions, upgrade both together. Lazy.nvim users on `branch = "main"` or `version = "*"` are fine.

## [1.7.0] - 2026-04-19

- **Feature:** `browser` config option to override the system default browser (#11)
  - `browser = nil` (default): system default
  - `browser = "Firefox"`: browser by app/binary name (macOS uses `open -a`)
  - `browser = { "google-chrome", "--incognito" }`: full command with args

## [1.6.0] - 2026-04-19

- **Fix:** overlay zoom-in no longer cuts off content. The fullscreen mermaid viewer now properly scrolls when zoomed beyond the viewport (#11)
- **Feature:** `bottom_padding` config option (0–1 fraction) controls how far the last line can scroll. Default 0.5 means the final line scrolls to the viewport midpoint (#12)
- **Feature:** WSL support: the preview now opens via `explorer.exe` on Windows Subsystem for Linux (#14)

## [1.5.3] - 2026-03-24

- Strip YAML front matter from preview: metadata blocks no longer render as headings/text

## [1.5.2] - 2026-03-21

- Add task list checkbox rendering (`- [ ]` / `- [x]`) via markdown-it-task-lists

## [1.5.1] - 2026-03-13

- Remove heading anchor permalink symbols (#) from preview for cleaner readability

## [1.5.0] - 2026-03-13

- Add takeover instance mode (default): single browser tab shared across Neovim instances via lock file coordination
- Add multi instance mode: independent server and browser tab per instance (port 0)
- Add lock file and remote event modules for cross-instance coordination
- Secondary instances get scroll sync via HTTP event injection

## [1.4.0] - 2026-02-21

### What's new

#### LaTeX math rendering

Added support for LaTeX math via [KaTeX](https://katex.org/) and [markdown-it-texmath](https://github.com/goessner/markdown-it-texmath).

- Inline math: `$E = mc^2$`
- Display math: `$$\int_0^\infty e^{-x^2} dx$$`
- LaTeX environments: `\begin{equation}...\end{equation}`

All loaded from CDN, zero extra dependencies. Just update and it works.

Closes #6

## [1.3.0] - 2026-02-15

### What's new

#### Line-based scroll sync

Rewrote scroll sync from heading-based to line-based interpolation, inspired by peek.nvim and iamcco/markdown-preview.nvim.

**Before:** Only headings were tracked (5-15 anchor points), scrolling up was inconsistent, files without headings had no sync at all.

**After:** Every block element (paragraphs, headings, lists, tables, blockquotes, code blocks) is tagged with its source line number. The browser interpolates between the nearest elements for sub-element precision. Scrolling is instant (no animation fighting) and works in both directions consistently.

**Fixes:**
- Scrolling up no longer fights with itself
- Files with no headings now scroll correctly
- Layout shifts (images loading) re-apply scroll position automatically

## [1.2.1] - 2026-02-15

### Fixed

- Scroll sync heading detection was broken due to Lua pattern `{n,m}` quantifier not being supported (treated as literal text). Headings are now correctly matched.
- Removed debug logging left from development.
- Updated README with scroll sync documentation and fixed stale keymap references in troubleshooting.

## [1.2.0] - 2026-02-15

### New

**Heading-based scroll sync**

As you move your cursor between sections in Neovim, the browser preview smoothly scrolls to the corresponding heading. No configuration needed: enabled by default.

- Tracks the nearest heading above the cursor via `CursorMoved` autocmd
- Sends a lightweight SSE event only when the heading changes (no unnecessary traffic)
- Browser uses `scrollIntoView({ behavior: 'smooth' })` for a polished experience
- Disable with `scroll_sync = false` in setup if not wanted

Requires live-server.nvim v1.1.0+ (for `send_event` API).

Closes #5

## [1.1.1] - 2026-02-13

### Changes

- Removed default keymaps: commands (`:MarkdownPreview`, `:MarkdownPreviewRefresh`, `:MarkdownPreviewStop`) are still registered, but keymaps are now left to the user to avoid conflicts
- Added suggested keymap snippet to README for easy copy-paste

Closes #4

## [1.1.0] - 2026-02-12

### New Features

#### Optional Rust-powered mermaid rendering

Pre-render mermaid diagrams on the Neovim side via the [`mmdr`](https://github.com/mermaid-rs/mermaid-rs-renderer) CLI: roughly **400x faster** than browser-side mermaid.js.

```lua
require("markdown_preview").setup({
  mermaid_renderer = "rust",  -- default: "js"
})
```

- Install: `cargo install mermaid-rs-renderer`
- Failed blocks fall back to browser-side rendering automatically (per-block)
- Default remains `"js"`: zero external dependencies preserved
- Expand/zoom/pan/export all work on pre-rendered diagrams

#### Colored heading borders

Headings (h1–h6) now have a colored left border for improved readability and visual hierarchy:

| Level | Color |
|-------|-------|
| h1 | Blue |
| h2 | Purple |
| h3 | Green |
| h4 | Teal |
| h5 | Amber |
| h6 | Gray |

Colors adapt to dark/light theme and match the existing callout/admonition palette.

### Other Improvements

- Polished browser tab lifecycle: graceful reconnect when tab is closed and reopened
- Improved Markdown visual handling (better spacing, typography)

## [1.0.0] - 2026-02-12

Complete rewrite from `mermaid-playground.nvim` to `markdown-preview.nvim`.

### Highlights

- **Full Markdown rendering** in the browser: headings, tables, code blocks, lists, images, links, blockquotes, horizontal rules
- **First-class Mermaid diagram support** with interactive SVGs (expand, zoom, pan, export)
- **Instant live updates** via Server-Sent Events (no polling)
- **Syntax-highlighted code blocks** (highlight.js) with language badges and copy button
- **GitHub-flavored callouts/admonitions**: note, tip, warning, caution, important
- **Dark / Light theme** toggle
- **Per-diagram error handling** with graceful fallback to last good render
- **Iconify icon pack** auto-detection
- **Efficient DOM diffing** via morphdom: scroll position preserved, no flicker
- **`.mmd` / `.mermaid` file support**: entire file rendered as a diagram
- **Zero external dependencies**: no npm, no Node.js, just Neovim + your browser
- Powered by [live-server.nvim](https://github.com/selimacerbas/live-server.nvim) (pure Lua HTTP server)

### Install

```lua
-- lazy.nvim
{
  "selimacerbas/markdown-preview.nvim",
  dependencies = { "selimacerbas/live-server.nvim" },
  config = function()
    require("markdown_preview").setup()
  end,
}
```

[Unreleased]: https://github.com/selimacerbas/mdkite.nvim/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/selimacerbas/mdkite.nvim/releases/tag/v2.1.0
[2.0.0]: https://github.com/selimacerbas/mdkite.nvim/releases/tag/v2.0.0
[1.10.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.10.0
[1.9.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.9.0
[1.8.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.8.0
[1.7.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.7.0
[1.6.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.6.0
[1.5.3]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.5.3
[1.5.2]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.5.2
[1.5.1]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.5.1
[1.5.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.5.0
[1.4.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.4.0
[1.3.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.3.0
[1.2.1]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.2.1
[1.2.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.2.0
[1.1.1]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.1.1
[1.1.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.1.0
[1.0.0]: https://github.com/selimacerbas/markdown-preview.nvim/releases/tag/v1.0.0
