# Recall App

A native macOS app to **browse, search, and read** your Claude Code & Codex
sessions. It's the desktop counterpart to the [`recall`](../recall) CLI — the
GUI shells out to the installed `recall` binary for search, so the two can never
disagree on what a search means.

- **Bundle id:** `io.github.ramsrib.recall`
- **Display name:** Recall App
- **Stack:** SwiftUI (SwiftPM executable), macOS 14+

## How it works

| Feature | Mechanism |
|---|---|
| **Browse** | Scans `~/.claude/projects/**/*.jsonl` and `~/.codex/{sessions,archived_sessions}/**/rollout-*.jsonl` directly (cheap 64 KB head read per file for title/project/mtime). |
| **Search** | Runs `~/.local/bin/recall "<query>" --mode … --source … --limit 50` and decodes its JSON. Modes: Hybrid / Semantic / Lexical / All-keywords. |
| **Read** | Full-parses the selected transcript and renders messages — prose as Markdown, fenced code in monospaced boxes, `thinking` / tool calls / tool results collapsible. |
| **Reindex** | Streams `recall index` progress (⌘⇧R). |
| **Deep link** | `recall://session/<id>` opens that thread — launching the app if it isn't running. |

Semantic & Hybrid search need [Ollama](https://ollama.com) running (that's the
CLI's requirement). If it's down, the app surfaces the error and offers a
one-click fallback to Lexical, which needs nothing.

## Deep links

Open a specific session from anywhere — a terminal, a note, a script:

```sh
open "recall://session/<session-id>"
```

The app launches if it isn't already running, comes to the front, and selects
that thread. If the session is hidden by the current filter (e.g. you're viewing
Claude and the link points at a Codex session), the view switches to one that
shows it. The id is the `session_id` that `recall list` prints.

> The `recall://` scheme is registered only by the packaged app (`make app` /
> `make install`), not by `make run` / `swift run`.

## Build & run

```sh
make run                 # dev loop — build + launch via SwiftPM
make app                 # package "build/Recall App.app" (bundle id baked in)
make open                # package, then open the .app
```

Requires the `recall` CLI installed (`make install` in the recall repo →
`~/.local/bin/recall`).

## Status

v1: browse + search + read working. Not yet done: in-transcript snippet
highlighting/jump-to-match, project sidebar grouping, bundling the `recall`
binary inside the .app (currently calls the installed one), live result preview.
