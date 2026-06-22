# Recall App — Vision & Direction

> The north-star doc. High-level intent, product shape, design language, and the
> key decisions behind them. Deliberately **not** an implementation spec — no
> code, no exact flags. When in doubt, this doc explains *why*; the code explains *how*.

---

## One line

**Recall App is a manager for your AI coding threads** — a "read-it-later / tab
manager" for Claude Code & Codex sessions, so you can stop hoarding terminal tabs.

## The problem

You run 10+ Claude/Codex sessions at once. Each one is a *thought* — a thread you
want to leave open and come back to, because you're constantly juggling different
priorities. Today the only way to "keep a thread alive" is to keep its terminal
tab open. That doesn't scale: tabs pile up, you're afraid to close any of them,
and the knowledge inside finished sessions is effectively write-only.

The `recall` CLI helps you *find* a session, but its value is capped: even when
it returns the right hit, it takes real time to read through the message history
to confirm it's the one you wanted, or to remember where you left off.

## The insight

The job isn't "search my archive." It's **manage and resume active threads**.
If sessions are easy to glance at, pin, and resume, then a terminal tab stops
being precious — you can close it and trust you'll get back exactly where you left.

Mental model: **a calm inbox of your thinking threads.**

## Who it's for

You. A single-user, **local-first** tool — nothing leaves the machine. Built for a
power user who lives in Claude Code / Codex and accumulates many sessions worth
returning to.

---

## Jobs to be done

1. **"Where did I leave off?"** — reopen a thread and resume it without having kept
   its terminal alive.
2. **"Is this the one?"** — glance at what a session covered (it may have done ten
   different things, or one focused thing) without re-reading the whole transcript.
3. **"Keep these handy."** — pin the handful of threads I'm actively juggling.
4. **"What was I working on?"** — scan recent threads across tools to rebuild context.
5. **"Find that old conversation."** — search to surface something from weeks ago.

## What it does — in priority order

1. **List** — a clean, recency-grouped list of all sessions:
   **Pinned · Today · Yesterday · This Week · Older**.
   *Source-agnostic*: Claude vs Codex is a quiet badge, never a navigation axis.
2. **Glance (summary)** — click a session to see an at-a-glance summary of what it
   covered and where it started/ended. **This is the make-or-break feature** — it
   removes the CLI's core friction (verifying a hit by reading the whole thread).
3. **Read** — a nicely formatted transcript, opened only when you want the detail.
4. **Pin / unpin** — keep active threads at the top.
5. **Resume** — one click relaunches the thread in a terminal tab, in its project
   directory, so closing terminals is safe.
6. **Search** — a quiet way in for older threads. Secondary, not the center.

## Non-goals (what it deliberately is *not*)

- **Not cloud / not sync.** Local only. No accounts.
- **Not an editor.** Sessions are read-only artifacts.
- **Not a re-implementation of search.** It leans on the `recall` engine.
- **Not a generic log viewer.** It's opinionated around *threads you return to*.
- **Not married to one terminal**, but Tarp-first by design.

---

## Design language

**Monochromatic and distraction-free.** The content is the interface.

- **Grayscale.** One near-black "ink" for text on a calm near-white surface. A
  single restrained accent (a hairline / subtle fill) for selection and pins —
  nothing else competes for attention.
- **No color-coding** by source or message role. Source is a small text badge.
- **Reading is sacred.** The transcript reader is the quietest space in the app —
  generous whitespace, comfortable measure, system font for prose, monospaced only
  for code.
- **Calm density.** The list is scannable at a glance; time-grouping does the
  organizing so the eye doesn't have to.
- **Keyboard-first.** It's a power-user tool: navigate, pin, resume, and search
  from the keyboard.

---

## Architecture — two companions

Recall App and the `recall` CLI are **companions that share one engine**.

- **`recall` (Go CLI) — the engine & data layer.** Owns session discovery, the
  local index/DB, search, and (extended over time) listing, summaries, pin state,
  and resume-command construction. Headless, scriptable, useful on its own in the
  terminal.
- **Recall App (SwiftUI) — the presentation layer.** A thin, beautiful client that
  renders the manager UX, reads transcripts for the reader, and triggers actions.

**Principle:** if logic is reusable or headless, it belongs in the CLI; the app
owns only what's inherently native (windows, keyboard, pin gestures, launching the
terminal). This keeps the two permanently in sync and makes the CLI richer for
direct terminal use.

**Proposed CLI surface** (grows as the app needs it):

| Capability | Lives in CLI as | Consumed by |
|---|---|---|
| Search | `recall "query"` *(exists)* | app + terminal |
| Index | `recall index` *(exists)* | app + terminal |
| List sessions + metadata | `recall list` | app (the main list) |
| Per-session summary (generate + cache) | `recall summary <id>` | app (glance) + terminal |
| Pin / unpin | `recall pin` / `unpin` | app + terminal |
| Resume a thread | `recall resume <id>` | app + terminal |

A useful consequence: making the CLI the source of truth for **list** resolves the
"scan disk vs. read the index" question — the app stops scanning disk itself and
asks `recall` instead.

---

## Key integrations

### Summaries → `codex` (local, cached)
Summaries are generated by the **Codex CLI** run non-interactively, reading the
transcript and returning a concise overview (topics covered, start → end). It runs
in a read-only, no-execution mode, and every summary is **cached** (keyed to the
session and its last-modified time) so it's computed once per session.

### Resume → Tarp, via its **local** features
[Tarp](https://tarp.dev) is a cloud-free, account-free, AI-free fork of Warp.
Resume uses **only Tarp's local surface** — tab configs / workflows / open-in-tab
(`tarp://` deep links and tab-config files that run a command on open). The app
generates the right resume invocation (`claude --resume <id>` or
`codex resume <id>`) in the session's project directory and opens it as a new
Tarp tab. A clipboard fallback covers any edge case.

> Explicitly **not used:** Warp's "Oz" cloud-agent CLI or its local HTTP server —
> those are cloud/agent orchestration and run against Tarp's no-cloud ethos.

---

## Decision log

| Date | Decision |
|---|---|
| 2026-06-21 | Name: **Recall App**; bundle id `io.github.ramsrib.recall`; private repo `ramsrib/recall-app`. |
| 2026-06-21 | Stack: **SwiftUI**, macOS 14+. |
| 2026-06-21 | Product is a **thread manager**, not a search archive. Search demoted to a secondary filter. |
| 2026-06-21 | Architecture: **CLI = engine/data, app = presentation**; extend `recall` with `list` / `summary` / `pin` / `resume`. |
| 2026-06-21 | Summaries via the **Codex CLI** (local, cached). |
| 2026-06-21 | Resume via **Tarp local** tab-config / open-in-tab (cloud-free); never Oz cloud. |
| 2026-06-21 | Design: **monochromatic, distraction-free**, keyboard-first. |
| 2026-06-21 | **Deep links**: a `recall://session/<id>` URL scheme opens a thread by id. Consumer-only for now — the app handles incoming links; no in-app "Copy Link" or CLI link-emitter yet. |
| 2026-06-22 | **Mentes tasks**: surface the `<id>.mentes.jsonl` sidecar in the app — a list badge when the sidecar *exists* (cheap existence check), and a detail **Mentes Tasks** section that reads it on open, with `mentes-tasks://tasks/<id>` deep links out (the scheme the Mentes Tasks app claims). Read **app-side** (the sidecar is a sibling file the app already has the path to — same pattern as the transcript reader), not via the CLI: an early `recall mentes` command was added then removed as unnecessary, since reading it needs nothing from the recall engine/DB. (Pinned/archived legitimately come from the CLI — pin state lives in the DB, archived is a directory — but mentes-has-tasks is fully file-derivable.) |

## Open questions

- **Summary shape** — topic outline, short prose, or topics + a start→end timeline?
- **When summaries run** — lazily on first open, prefetched for recent threads, or
  in the background after indexing?
- **List freshness** — does `recall list` scan disk live (always truthful) or read
  the index (faster, can lag)? Likely a hybrid.
- **Resume targets** — Tarp first; do we add a Ghostty fallback later?
- **Pin storage** — shared in the `recall` DB so pins are consistent across CLI and
  app (leaning yes).
