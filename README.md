# Recall App

A native macOS app to **browse, read, and resume** your Claude Code & Codex
sessions — a thread manager for AI coding work, so a terminal tab stops being
precious.

It is the desktop companion to the [`recall`](https://github.com/ramsrib/recall-cli)
CLI. The app is a thin client: listing, summaries, pin state, resume commands, and
indexing all come from the installed `recall` binary, so the GUI and the terminal
can never disagree. Transcripts are read directly off disk.

- **Bundle id:** `io.github.ramsrib.recall`
- **Stack:** SwiftUI (SwiftPM executable), macOS 14+

## Requirements

- **macOS 14+**, and a Swift 5.9 toolchain (Xcode or the Command Line Tools) to build.
- **The `recall` CLI** — [github.com/ramsrib/recall-cli](https://github.com/ramsrib/recall-cli).
  This is a hard dependency: without it the session list, summaries, pin, resume,
  and reindex are all unavailable, and the app says so. The app looks for the
  binary at exactly these paths — not on your `$PATH`:

  ```
  ~/.local/bin/recall      # where the CLI's `make install` puts it
  /opt/homebrew/bin/recall
  /usr/local/bin/recall
  ```

- **[Ollama](https://ollama.com)**, running locally with an embedding model — a
  requirement inherited from the CLI, which computes embeddings locally to build
  its index:

  ```sh
  ollama pull qwen3-embedding:0.6b
  ```

  Ollama is needed to **index** (the app's Reindex, ⌘⇧R) and for the CLI's
  Semantic and Hybrid search. The CLI's Lexical (keyword/BM25) search needs
  nothing. Once an index exists, browsing and reading in the app do not touch
  Ollama.

- **`ccusage`** — optional, only for the Usage page. Looked for in
  `/opt/homebrew/bin`, `~/.local/bin`, `/usr/local/bin`, `~/.bun/bin`.
- **[Tarp](https://github.com/ramsrib/tarp)** — optional, only for Resume. See below.

First run: install the CLI, `recall index` once, then build and launch the app.

## Build & run

```sh
make build     # swift build
make run       # dev loop — build + launch via SwiftPM
make app       # package build/Recall App.app (bundle id + URL scheme baked in)
make open      # package, then open the .app
make install   # package and install to /Applications
make clean     # rm -rf .build build
```

The packaged app is **ad-hoc signed and not notarized** — fine locally, but it is
not a distributable build.

## What it does

| | |
|---|---|
| **Browse** | Sessions come from `recall list --mode all`, grouped by recency: Pinned · Parked · Today · Yesterday · This Week · Older. The list refreshes when the app regains focus. |
| **Filter** | Sidebar: All, Pinned, Parked, Archived, Automation, Claude, Codex, and per-project. The search field (⌘K) is a **filter over the loaded list** — substring match on session title and project path. Full-text and semantic search over transcript *content* live in the CLI (`recall "query"`), not in the app. |
| **Read** | The selected transcript is parsed in full and rendered: prose as text, code in monospaced blocks, reasoning / tool calls / tool results collapsible. |
| **Details** | Model, CLI version, token totals (input / cache / output), message count, and duration — derived from the transcript itself, no `ccusage` round-trip. |
| **Summary** | `recall summary` (which shells out to the Codex CLI, and caches). Opening a session shows a **cached** summary if one exists; generating is always an explicit click, so no session ever silently spends a model call. |
| **Pin** | `recall pin` / `recall unpin`. Pinned threads float to the top of every filter. |
| **Resume** | `recall resume` returns the command and project dir; the app launches it in Tarp, or copies it to the clipboard. |
| **Reindex** | Streams `recall index` progress (⌘⇧R). |
| **Usage** | Optional token/cost dashboard (⌘U) from `ccusage --json`. Hidden behind a clear error if `ccusage` isn't installed. |
| **Deep links** | `recall://session/<id>` opens that thread. |

Right-click a session for **Copy Session ID**, **Copy Link**, **Pin/Unpin**, and
**Reveal in Finder**.

## Deep links

```sh
open "recall://session/<session-id>"
```

The app launches if it isn't running, comes to the front, and selects that thread —
switching filters if the session is hidden by the current one. A link opened before
the list has loaded is applied once it does. The id is the `session_id` that
`recall list` prints.

> The `recall://` scheme is registered only by the **packaged** app (`make app` /
> `make install`), not by `make run` / `swift run`.

## Resume

`recall resume <id>` yields the resume command (`claude --resume <id>` or
`codex resume <id>`) and the session's project directory. If
[Tarp](https://github.com/ramsrib/tarp) is installed at `/Applications/Tarp.app`,
the app writes a launch configuration to `~/.tarp/launch_configurations/` and opens
it with a `tarp://` link, which runs the command in a new tab in that directory.

If Tarp isn't installed, the command is copied to your clipboard instead — the app
always copies it, so Resume is useful with any terminal.

## Optional sidecar integration

If a file named `<transcript>.mentes.jsonl` sits next to a session's transcript —
that is, the transcript's own filename with `.jsonl` replaced by `.mentes.jsonl` —
the app reads it and surfaces the tasks it lists: a small badge in the session
list, and a **Tasks** section in the detail view with a link out to a companion app
that registers the `mentes-tasks://` scheme. A `.park.json` marker alongside a
transcript likewise surfaces a **Parked** banner and sidebar filter.

These files are produced by external tooling, not by this app. **If they don't
exist, nothing appears** — no badge, no section, no error, no prompt, no network
call. That is the normal case, and the app is fully functional without them.

> Note the sidecar is named after the **transcript file**, not the session id.
> They coincide for Claude (`<uuid>.jsonl`), but a Codex transcript is
> `rollout-…-<uuid>.jsonl`, so its sidecar is `rollout-…-<uuid>.mentes.jsonl`.

## Privacy

The app reads transcript files from your disk and shells out to the `recall` and
`ccusage` binaries. It performs no network requests of its own and sends no
telemetry. The one exception worth naming: **generating a summary** runs
`recall summary`, which invokes the Codex CLI on the transcript — so that content
goes wherever your Codex CLI is configured to send it. Summaries are only ever
generated when you click to generate one.

## Design

[`docs/vision.md`](docs/vision.md) covers the product shape and the reasoning
behind the CLI/app split.

The Claude and Codex marks in the sidebar are monochrome vector *recreations*
drawn in-app, not bundled brand assets. They are stand-ins for identification only;
the trademarks belong to their respective owners.

## License

MIT — see [LICENSE](LICENSE).
