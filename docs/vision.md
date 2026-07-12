# Design notes

Why Recall App is shaped the way it is. The code explains *how*; this explains
*why*. Not a spec — no flags, no APIs.

## The problem

Running many Claude Code / Codex sessions at once, each session is a thread you
want to leave open and come back to. Today the only way to keep a thread alive is
to keep its terminal tab open. That doesn't scale: tabs pile up, none feel safe to
close, and the knowledge inside finished sessions is effectively write-only.

The `recall` CLI helps you *find* a session, but its value is capped: even when it
returns the right hit, it takes real time to read the message history to confirm
it's the one you wanted, or to remember where you left off.

## The insight

The job isn't "search my archive." It's **manage and resume active threads**. If
sessions are easy to glance at, pin, and resume, a terminal tab stops being
precious — you can close it and trust you'll get back to where you left off.

Mental model: a calm inbox of your thinking threads.

## What it does, in priority order

1. **List** — a recency-grouped list of all sessions: Pinned · Parked · Today ·
   Yesterday · This Week · Older. Source (Claude / Codex), project, pinned,
   archived, and automation runs are filters in the sidebar.
2. **Glance** — select a session to see a cached summary of what it covered.
   This removes the CLI's core friction: verifying a hit by reading the thread.
   Summaries are never generated implicitly — opening a session shows a cached
   one if it exists, and generation is an explicit click.
3. **Read** — the full transcript, formatted: prose as text, code in monospaced
   blocks, reasoning / tool calls / tool results collapsible.
4. **Pin / unpin** — keep active threads at the top.
5. **Resume** — relaunch the thread in a terminal, in its project directory, so
   closing terminals is safe.

## Non-goals

- **Not an editor.** Sessions are read-only artifacts.
- **Not a re-implementation of search.** Indexing and search live in the CLI.
- **Not a generic log viewer.** It's opinionated around *threads you return to*.
- **Not married to one terminal.** Resume falls back to the clipboard.

## Design language

Monochromatic and distraction-free — the content is the interface.

- **Grayscale.** One near-black ink on a calm surface, with a single restrained
  accent (a hairline / subtle fill) for selection and pins.
- **No color-coding** by source or message role. Source is a small badge.
- **Reading is sacred.** The transcript reader is the quietest space in the app:
  generous whitespace, system font for prose, monospaced only for code.
- **Calm density.** Time-grouping does the organizing so the eye doesn't have to.

## Architecture — two companions

Recall App and the `recall` CLI share one engine.

- **`recall` (Go CLI) — the engine and data layer.** Owns session discovery, the
  local index, search, listing, summaries, pin state, and resume-command
  construction. Headless and scriptable, useful on its own.
- **Recall App (SwiftUI) — the presentation layer.** A thin client that renders
  the manager UX, reads transcripts for the reader, and triggers CLI actions.

**Principle:** if logic is reusable or headless, it belongs in the CLI; the app
owns only what is inherently native — windows, keyboard, pin gestures, launching
a terminal. This keeps the two permanently in sync and makes the CLI richer for
direct terminal use.

The app therefore depends on this CLI surface:

| Capability | CLI command |
|---|---|
| List sessions + metadata | `recall list --mode all` |
| Per-session summary (generate + cache) | `recall summary <id> [--refresh\|--cached-only]` |
| Pin / unpin | `recall pin <id>` / `recall unpin <id>` |
| Resume a thread | `recall resume <id>` |
| Reindex | `recall index` |

Making the CLI the source of truth for **list** is what lets the app stop scanning
disk itself: it asks `recall` instead, so the GUI and the terminal can't disagree
about what sessions exist.

Two things are deliberately *not* routed through the CLI, because they are plain
sibling files the app already has the path to — reading them needs nothing from
the index: the transcript itself (for the reader) and the optional task sidecar.

## Integrations

**Summaries → the Codex CLI.** `recall summary` shells out to `codex` to read the
transcript and return a short overview (Gist / Key points / Outcome / Next), and
caches it per session. This is the one part of the system that is not purely
local: summary generation sends transcript content to whatever model provider the
Codex CLI is configured against. Everything else — listing, reading, pinning,
resuming — is local file and index access. The app never generates a summary on
its own; you have to ask for one.

**Resume → Tarp.** [Tarp](https://github.com/ramsrib/tarp) is a terminal the app
can launch a session into. Resume writes a launch configuration that opens a tab
in the session's project directory and runs the resume command (`claude --resume
<id>` or `codex resume <id>`), then opens it via a `tarp://` deep link. Tarp is
optional: without it, the resume command is copied to the clipboard instead, which
is also the fallback for any edge case.

**Tasks → an optional sidecar.** If a `.mentes.jsonl` file sits next to a
session's transcript, the app surfaces the tasks it lists and can deep-link out to
a companion app. No sidecar, nothing shows — no error, no prompt, no network. See
the README.
