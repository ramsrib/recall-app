import SwiftUI
import AppKit

/// Search text in isolation. Held by SessionListView via @State (NOT observed),
/// so typing re-renders only SessionListContent (which @ObservedObject's it),
/// never the toolbar host — that's what keeps the search field from being
/// recreated and losing focus on every keystroke.
final class SearchModel: ObservableObject {
    @Published var text = ""
}

struct SessionListView: View {
    @EnvironmentObject var app: AppState
    @State private var search = SearchModel()     // @State = hold, don't observe
    @State private var searchExpanded = false
    @State private var columnWidth: CGFloat = 380

    var body: some View {
        SessionListContent(search: search)
            .background(Color(nsColor: .windowBackgroundColor))
            // Measure the column so the expanded search can span it — the
            // toolbar item can't see how wide its column is on its own.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ListColumnWidth.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(ListColumnWidth.self) { width in
                Task { @MainActor in columnWidth = width }
            }
            // Search collapses to a magnifying glass until it's used — an idle
            // text box was eating toolbar width the title wants. `.searchable`
            // can't do this on macOS (`.searchToolbarBehavior(.minimize)` is
            // iOS-only), so this is a hand-rolled equivalent.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SearchControl(model: search, expanded: $searchExpanded,
                                  expandedWidth: max(180, columnWidth - 44))
                }
            }
            .onChange(of: app.searchFocusRequested) { _, req in   // ⌘K
                if req { searchExpanded = true; app.searchFocusRequested = false }
            }
    }
}

/// Collapsing toolbar search: a magnifying-glass button that expands into a
/// search field, all in ONE AppKit view.
///
/// It's deliberately not SwiftUI. Two things fail inside an `NSToolbar` item:
/// `@FocusState` never takes hold (⌘K expanded an unfocused box and swallowed
/// the keystrokes), and swapping the item's content between two SwiftUI views
/// leaves the tap gesture dead afterwards — the icon still highlights on hover
/// but clicks do nothing. One NSView with a stable identity, doing its own
/// focus and hit-testing, has neither problem.
private struct SearchControl: View {
    let model: SearchModel                  // written to, never observed
    @Binding var expanded: Bool
    let expandedWidth: CGFloat
    @State private var text = ""

    var body: some View {
        CollapsingSearchBar(text: $text, expanded: $expanded, expandedWidth: expandedWidth)
            .onChange(of: text) { _, new in model.text = new }
            .help("Search sessions (⌘K)")
    }
}

private struct CollapsingSearchBar: NSViewRepresentable {
    @Binding var text: String
    @Binding var expanded: Bool
    let expandedWidth: CGFloat

    func makeNSView(context: Context) -> CollapsingSearchView {
        let view = CollapsingSearchView()
        view.onTextChange = { context.coordinator.parent.text = $0 }
        view.onExpandedChange = { context.coordinator.parent.expanded = $0 }
        return view
    }

    func updateNSView(_ view: CollapsingSearchView, context: Context) {
        context.coordinator.parent = self
        if view.field.stringValue != text { view.field.stringValue = text }
        view.expandedWidth = expandedWidth
        view.setExpanded(expanded)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CollapsingSearchView,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func dismantleNSView(_ view: CollapsingSearchView, coordinator: Coordinator) {
        view.stopWatchingForOutsideClicks()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: CollapsingSearchBar
        init(_ parent: CollapsingSearchBar) { self.parent = parent }
    }
}

/// The button + field pair. SwiftUI owns `expanded`; every AppKit-side collapse
/// (Esc, a click elsewhere) reports back up through `onExpandedChange` rather
/// than flipping state locally, so the two can't drift.
final class CollapsingSearchView: NSView, NSSearchFieldDelegate {
    private static let collapsedWidth: CGFloat = 28
    private static let height: CGFloat = 24

    /// How wide the field runs once open — the session list column's width,
    /// handed down from SwiftUI.
    var expandedWidth: CGFloat = 210 {
        didSet { if expandedWidth != oldValue, isExpanded { invalidateIntrinsicContentSize() } }
    }

    let field = NSSearchField()
    private let button = NSButton()
    private var isExpanded = false
    private var outsideClickMonitor: Any?
    private var hovering = false

    var onTextChange: ((String) -> Void)?
    var onExpandedChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        button.image = NSImage(systemSymbolName: "magnifyingglass",
                               accessibilityDescription: "Search sessions")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(expandFromButton)
        addSubview(button)

        field.delegate = self
        field.placeholderString = "Search title or project"
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.isHidden = true
        addSubview(field)

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: isExpanded ? expandedWidth : Self.collapsedWidth, height: Self.height)
    }

    override func layout() {
        super.layout()
        button.frame = bounds
        field.frame = bounds
    }

    // MARK: Expand / collapse

    func setExpanded(_ expand: Bool) {
        guard expand != isExpanded else { return }
        isExpanded = expand
        field.isHidden = !expand
        button.isHidden = expand
        invalidateIntrinsicContentSize()
        if expand {
            // The field is only in the window once this layout pass commits.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.field)
            }
            startWatchingForOutsideClicks()
        } else {
            stopWatchingForOutsideClicks()
            // End editing for real. Just hiding the field leaves its field
            // editor as first responder, which paints a stray blinking caret
            // next to the collapsed magnifying glass.
            field.abortEditing()
            if let responder = window?.firstResponder as? NSView,
               responder === field || responder.isDescendant(of: field) {
                window?.makeFirstResponder(nil)
            }
        }
        needsDisplay = true
    }

    @objc private func expandFromButton() {
        onExpandedChange?(true)
    }

    /// Esc, or the field's own clear button, drops the filter *and* the field.
    /// Collapsing with a query still live would leave the list mysteriously
    /// short with nothing on screen to explain it.
    private func clearAndCollapse() {
        field.stringValue = ""
        onTextChange?("")
        onExpandedChange?(false)
    }

    // MARK: Outside clicks
    //
    // `controlTextDidEndEditing` isn't enough on its own: a click on something
    // that doesn't take first responder (most of this window's chrome) leaves
    // the field focused, so the box just sat there open.

    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isExpanded, event.window === self.window else { return event }
            let pointInView = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(pointInView) && self.field.stringValue.isEmpty {
                self.onExpandedChange?(false)
            }
            return event
        }
    }

    func stopWatchingForOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        button.contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        button.contentTintColor = .secondaryLabelColor
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ note: Notification) {
        onTextChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        if field.stringValue.isEmpty { onExpandedChange?(false) }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            clearAndCollapse()
            return true
        }
        return false
    }
}

/// Width of the session list column, reported up so the toolbar's search field
/// can match it when expanded.
private struct ListColumnWidth: PreferenceKey {
    static var defaultValue: CGFloat = 380
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SessionListContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var search: SearchModel
    @FocusState private var listFocused: Bool
    @State private var olderShown = 0

    var body: some View {
        // Compute the grouping ONCE per render. These were separate computed
        // properties, so each render re-ran app.groups() (re-filtering every
        // session) 5–6× — wasteful on every keystroke and as the index grows.
        let groups = app.groups(search.text)
        let olderTotal = groups.first { $0.bucket == .older }?.sessions.count ?? 0
        let recentCount = groups.filter { $0.bucket != .older }.reduce(0) { $0 + $1.sessions.count }
        let effectiveOlderShown = (recentCount == 0 && olderShown == 0) ? 10 : olderShown
        let displayGroups: [SessionGroup] = groups.compactMap { g in
            guard g.bucket == .older else { return g }
            let shown = Array(g.sessions.prefix(effectiveOlderShown))
            return shown.isEmpty ? nil : SessionGroup(bucket: .older, sessions: shown)
        }
        let flat = displayGroups.flatMap { $0.sessions }

        return Group {
            if let err = app.loadError {
                errorState(err)
            } else if app.sessions.isEmpty && app.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No matches", systemImage: "magnifyingglass",
                    description: Text(search.text.isEmpty
                        ? "Nothing in this filter."
                        : "Nothing matches “\(search.text)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listBody(displayGroups: displayGroups, flat: flat,
                         olderTotal: olderTotal, effectiveOlderShown: effectiveOlderShown)
            }
        }
        .onChange(of: app.sidebarItem) { _, _ in olderShown = 0 }
        .onChange(of: search.text) { _, _ in olderShown = 0 }
    }

    private func listBody(displayGroups: [SessionGroup], flat: [SessionMeta],
                          olderTotal: Int, effectiveOlderShown: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(displayGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session)
                                    .id(session.sessionID)
                                    .onTapGesture { app.select(session.sessionID); listFocused = true }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                    if effectiveOlderShown < olderTotal {
                        Button {
                            olderShown = effectiveOlderShown + 10
                        } label: {
                            Label("Load \(min(10, olderTotal - effectiveOlderShown)) more",
                                  systemImage: "ellipsis")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // The overlay scroller was the loudest thing in a quiet column.
            // `.never`, not `.hidden`: hidden still lets the scroller flash in
            // during a scroll.
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                switch direction {
                case .up:   app.selectAdjacentIn(flat, -1)
                case .down: app.selectAdjacentIn(flat, 1)
                default:    break
                }
            }
            // Scroll only for selections that may be off-screen (keyboard nav,
            // deep links). Doing it for every selectedID change re-centered the
            // row the user had just clicked, shifting the whole list under the
            // cursor mid-click.
            .onChange(of: app.revealRequest) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                app.revealRequest = nil
            }
        }
    }

    private func groupHeader(_ group: SessionGroup) -> some View {
        HStack(spacing: 6) {
            if group.bucket == .pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            if group.bucket == .parked { Image(systemName: "pause.circle.fill").font(.system(size: 9)) }
            Text(group.bucket.rawValue.uppercased())
            Spacer()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry") { Task { await app.load() } }
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

struct SessionRow: View {
    @EnvironmentObject var app: AppState
    let session: SessionMeta
    @State private var hovering = false

    // Derive selection live from the shared state instead of receiving it as a
    // frozen `let` from the parent. In a LazyVStack with pinned section headers,
    // the parent's ForEach builder isn't reliably re-run for rows whose identity
    // is unchanged, so a passed-in `selected` goes stale and the first
    // (auto-selected) row stays highlighted alongside a newly-tapped one. Reading
    // `app.selectedID` here means every selection change re-renders each row with
    // a fresh value — exactly one row can be selected.
    private var selected: Bool { app.selectedID == session.sessionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                pinButton.opacity(session.pinned || hovering ? 1 : 0)
            }
            HStack(spacing: 6) {
                SourceBadge(source: session.sourceKind)
                if session.isExec { TagBadge(text: "AUTOMATION") }
                if session.archived { TagBadge(text: "ARCHIVED") }
                Text(session.projectName).lineLimit(1)
                if session.hasSummary { Image(systemName: "sparkles").font(.system(size: 9)) }
                if app.parkedSessionIDs.contains(session.sessionID) {
                    Image(systemName: "pause.circle").font(.system(size: 9)).help("Parked session")
                }
                if app.mentesSessionIDs.contains(session.sessionID) {
                    Image(systemName: "checklist").font(.system(size: 9)).help("Has Mentes tasks")
                }
                Spacer(minLength: 4)
                Text(session.lastDate, format: .relative(presentation: .named))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Session ID") { setClipboard(session.sessionID) }
            Button("Copy Link") { setClipboard("recall://session/\(session.sessionID)") }
            Divider()
            Button(session.pinned ? "Unpin" : "Pin") { app.togglePin(session) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
            }
        }
    }

    private func setClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var rowBackground: Color {
        if selected { return .selectionFill }
        if hovering { return Color.primary.opacity(0.035) }
        return .clear
    }

    private var pinButton: some View {
        Button { app.togglePin(session) } label: {
            Image(systemName: session.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(session.pinned ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(session.pinned ? "Unpin" : "Pin")
    }
}

struct SourceBadge: View {
    let source: SessionSource
    var body: some View {
        Text(source.displayName.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

struct TagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}
