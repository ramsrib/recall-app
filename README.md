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
| **Mentes tasks** | Badges sessions that have a `<id>.mentes.jsonl` sidecar; the detail view reads it on open and lists the tasks, each with an Open-in-Mentes link. |

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

## Mentes tasks

If a session created or updated [Mentes](https://mentes.ai) tasks, a
`<session-id>.mentes.jsonl` sidecar sits next to its transcript — an append-log
of task events (`{ts, action, task_id, session_id, recall_url}`).

- **List badge** — sessions whose sidecar *exists* get a small task glyph. This
  is a pure existence check (the file isn't read), computed once when the list
  loads, so it stays cheap.
- **Detail section** — opening a session reads the sidecar directly (it's a
  sibling of a path the app already has — no `recall` round-trip) and shows a
  **Mentes Tasks** section: the distinct tasks (latest action, event count,
  time), each with a button that opens `mentes-tasks://tasks/<id>` (the scheme
  the Mentes Tasks app claims).

The reverse direction already exists: each sidecar line carries a `recall_url`
(`recall://session/<id>`), so Mentes can deep-link back into this app.

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
