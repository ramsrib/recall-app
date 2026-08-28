import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if let session = app.selectedSession {
                detail(session)
            } else {
                ContentUnavailableView("Select a session", systemImage: "text.bubble",
                                       description: Text("Pick a thread to read, summarize, or resume."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Actions float against the right edge, vertically centered, rather than
        // sitting in the toolbar. An overlay, not a safeAreaInset: an inset
        // shrinks the scroll view, which parked the scroller *inside* the rail
        // instead of at the window edge. The content clears the rail via
        // safeAreaPadding on the ScrollView below.
        .overlay(alignment: .trailing) {
            if let s = app.selectedSession { ActionRail(session: s) }
        }
        // The title plate hangs off the top edge as content, not as a toolbar
        // item: hiding the system item's glass capsule (needed to give the
        // plate its own shape) also turned the whole toolbar band opaque gray.
        .overlay(alignment: .top) {
            if app.selectedSession != nil, !app.titleCollapsed {
                OmniBar()
                    .allowsHitTesting(false)
                    // Reach up through the toolbar's safe-area inset. Without
                    // this the plate hangs below the toolbar band with a gap
                    // above it, and a square-topped shape floating in mid-air
                    // just looks broken.
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    private func detail(_ s: SessionMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let note = app.resumeNote { resumeBanner(note) }
                detailsSection(s)                                  // 1. Details (always first)
                if let park = app.parkMarker { parkBanner(park) }  // 2. Parked
                mentesSection                                      // 3. Tasks
                glanceSection                                      // 4. Summary
                Divider().overlay(Color.hairline)
                transcriptSection(s)                               // 5. Recent Messages
            }
            .frame(maxWidth: Theme.readerMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)            // center the reading column
            .padding(.horizontal, 36)
            // Clear the floating action rail. This is padding on the scrolled
            // content, NOT safeAreaPadding on the ScrollView — the latter moves
            // the scroller inward with it, so the scrollbar drew to the left of
            // the rail instead of at the window's edge.
            .padding(.trailing, 46)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.never)
        // Fade the title plate out once reading starts.
        .modifier(ScrollOffsetReporter { app.setTitleCollapsed($0 > 36) })
        // A new session (or coming back from Usage) starts at the top again —
        // bring the title back with it.
        .onChange(of: s.sessionID) { _, _ in app.setTitleCollapsed(false) }
        .onAppear { app.setTitleCollapsed(false) }
    }

    private func resumeBanner(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { app.resumeNote = nil } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    // MARK: Parked banner (sourced from the optional `.park.json` sidecar)

    private func parkBanner(_ park: ParkMarker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Parked").font(.system(size: 12, weight: .semibold))
                    if let status = park.statusDisplay { TagBadge(text: status.uppercased()) }
                }
                if let title = park.title, !title.isEmpty {
                    Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Resume this session with ▶ above.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let taskID = park.taskID { CopyButton(text: taskID, help: "Copy task ID") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    // MARK: Details (model + token usage — the header block above the summary)

    @ViewBuilder
    private func detailsSection(_ s: SessionMeta) -> some View {
        if let ins = app.sessionInsights, !ins.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Details")
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        SourceIcon(source: s.sourceKind, size: 13)
                        Text(ins.modelDisplay)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let cli = ins.cliVersion {
                            Text("\(s.sourceKind.displayName) \(cli)")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider().overlay(Color.hairline).padding(.vertical, 12)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        if ins.hasTokens {
                            metaStat("Total", UsageFormat.tokens(ins.totalTokens))
                            metaStat("Input", UsageFormat.tokens(ins.inputTokens))
                            if ins.cacheTokens > 0 { metaStat("Cache", UsageFormat.tokens(ins.cacheTokens)) }
                            metaStat("Output", UsageFormat.tokens(ins.outputTokens))
                        }
                        metaStat("Messages", "\(s.msgCount)")
                        metaStat("Duration", durationText(s))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
            }
        }
    }

    private func metaStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact elapsed span between the session's first and last message.
    private func durationText(_ s: SessionMeta) -> String {
        let secs = max(0, s.lastTs - s.firstTs)
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60, remMin = mins % 60
        if hrs < 24 { return remMin == 0 ? "\(hrs)h" : "\(hrs)h \(remMin)m" }
        let days = hrs / 24, remHr = hrs % 24
        return remHr == 0 ? "\(days)d" : "\(days)d \(remHr)h"
    }

    // MARK: Glance

    @ViewBuilder
    private var glanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                sectionLabel("Summary")
                Spacer()
                if let summary = app.summary, !app.summaryLoading {
                    CopyButton(text: summary, help: "Copy summary")
                    Button("Regenerate") { app.loadSummary(refresh: true) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }

            if app.summaryLoading {
                glanceCardWrapper {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating summary via codex…").foregroundStyle(.secondary).font(.callout)
                    }
                }
            } else if let summary = app.summary {
                GlanceCard(text: summary)
            } else if let err = app.summaryError {
                glanceCardWrapper {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err).font(.callout).foregroundStyle(.secondary)
                        Button("Try again") { app.loadSummary(refresh: false) }.controlSize(.small)
                    }
                }
            } else {
                Button { app.loadSummary(refresh: false) } label: {
                    Label("Generate summary", systemImage: "sparkles")
                }
            }
        }
    }

    private func glanceCardWrapper<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }

    // MARK: Tasks (from the optional sidecar; hidden when there are none)

    @ViewBuilder
    private var mentesSection: some View {
        if !app.mentesTasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Tasks")
                VStack(spacing: 0) {
                    ForEach(Array(app.mentesTasks.enumerated()), id: \.element.id) { i, task in
                        if i > 0 { Divider().overlay(Color.hairline) }
                        MentesTaskRow(task: task)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
            }
        }
    }

    // MARK: Transcript (auto-loaded)

    @ViewBuilder
    private func transcriptSection(_ s: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Recent Messages")
            if app.transcriptLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if app.readerItems.isEmpty {
                Text("No readable messages — the transcript file may have moved (try Reindex).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // .id resets the reader's window (and scroll) when the session changes.
                TranscriptReader(items: app.readerItems).id(s.sessionID)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Task row (from the optional sidecar)

private struct MentesTaskRow: View {
    @EnvironmentObject var app: AppState
    let task: MentesTask
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.action == "create" ? "plus.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.shortID).font(.system(size: 13, weight: .medium)).monospaced()
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CopyButton(text: task.taskID, help: "Copy task ID")
            Button { openInMentes() } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .help("Open task in Mentes")
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openInMentes() }
    }

    private var subtitle: String {
        var parts = [task.action.capitalized]
        if task.events > 1 { parts.append("\(task.events) events") }
        return parts.joined(separator: " · ")
            + " · " + task.date.formatted(.relative(presentation: .named))
    }

    private func openInMentes() {
        guard let url = URL(string: task.mentesURL) else { return }
        // Nothing may be registered to handle the scheme, in which case the open
        // fails silently — fall back to copying the link so the click still does
        // something visible.
        if !NSWorkspace.shared.open(url) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.mentesURL, forType: .string)
            app.resumeNote = "Couldn’t open Mentes — copied \(task.mentesURL) to the clipboard."
        }
    }
}

// MARK: - Glance card (light formatting of the codex summary)

struct GlanceCard: View {
    let text: String
    private static let labels: Set<String> = ["Gist", "Key points", "Outcome", "Next"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .lineSpacing(3)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
        .textSelection(.enabled)
    }

    // The card is plain text; codex sometimes wraps identifiers in `backticks`
    // (the prompt favors concrete service/file names) — strip them so they don't
    // render literally.
    private var lines: [String] {
        text.replacingOccurrences(of: "`", with: "").components(separatedBy: "\n")
    }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Color.clear.frame(height: 2)
        } else if t.hasPrefix("- ") || t.hasPrefix("• ") {
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                Text(String(t.dropFirst(2))).foregroundStyle(.primary)
            }
            .font(.system(size: 14))
        } else if let label = leadingLabel(t) {
            let rest = String(t.dropFirst(label.count))
            (Text(label).fontWeight(.semibold) + Text(rest)).font(.system(size: 14))
        } else {
            Text(t).font(.system(size: 14))
        }
    }

    private func leadingLabel(_ s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let word = String(s[s.startIndex..<colon])
        return Self.labels.contains(word) ? word + ":" : nil
    }
}

// MARK: - Scroll offset plumbing

/// Reports how far a scroll view is scrolled from its top (0 at rest).
///
/// A GeometryReader in a named coordinate space doesn't work here — macOS's
/// scroll views don't re-publish that geometry while scrolling, so it only ever
/// reported 0. `onScrollGeometryChange` is the API that actually tracks it
/// (macOS 15+; older systems simply keep the title pinned).
struct ScrollOffsetReporter: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, offset in
                onChange(offset)
            }
        } else {
            content
        }
    }
}

// MARK: - Floating action rail

/// Session actions as a small floating column pinned to the right edge of the
/// detail pane, vertically centered — always within reach while reading, and
/// out of the toolbar so the title can use its full width.
struct ActionRail: View {
    @EnvironmentObject var app: AppState
    let session: SessionMeta

    var body: some View {
        VStack(spacing: 2) {
            RailButton(icon: "play.fill", help: "Resume session",
                       disabled: !app.recallAvailable) { app.resume(session) }
            RailButton(icon: session.pinned ? "pin.fill" : "pin",
                       help: session.pinned ? "Unpin" : "Pin",
                       active: session.pinned) { app.togglePin(session) }
            RailButton(icon: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.path)])
            }
        }
        .padding(4)
        // Solid page background, not a material — material over the white
        // reading pane just read as a gray smudge.
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(Color.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 7, y: 2)
        .padding(.trailing, 14)
    }
}

private struct RailButton: View {
    let icon: String
    let help: String
    var active = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary)
                                          : AnyShapeStyle(active || hovering ? Color.primary
                                                                             : Color.secondary))
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(hovering && !disabled ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}
