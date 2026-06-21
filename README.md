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

Semantic & Hybrid search need [Ollama](https://ollama.com) running (that's the
CLI's requirement). If it's down, the app surfaces the error and offers a
one-click fallback to Lexical, which needs nothing.

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
