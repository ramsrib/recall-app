import SwiftUI
import AppKit

// MARK: - Reader (flattens messages, groups consecutive tool calls)

struct TranscriptReader: View {
    /// Reader items in chronological order (built once in AppState, off-main).
    let items: [ReaderItem]

    // Render newest-first, windowed: only the most recent `window` items mount,
    // inside a LazyVStack so off-screen rows aren't built. "Load older" extends
    // the window. Together these keep even multi-hundred-message sessions snappy.
    @State private var window = pageSize
    private static let pageSize = 30

    private var shown: [ReaderItem] {
        // suffix(window) = the newest `window` chronological items; reverse so the
        // most recent sits on top. Avoids reversing the whole array.
        Array(items.suffix(window).reversed())
    }
    private var remaining: Int { max(0, items.count - window) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(shown) { row($0) }
            if remaining > 0 {
                Button {
                    window += Self.pageSize
                } label: {
                    Label("Load \(min(Self.pageSize, remaining)) older message\(min(Self.pageSize, remaining) == 1 ? "" : "s")",
                          systemImage: "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ReaderItem) -> some View {
        switch item.kind {
        case .user(let t, let d):  ChatBubble(text: t, time: d, isUser: true)
        case .agent(let t, let d): ChatBubble(text: t, time: d, isUser: false)
        case .reasoning(let t):    ReasoningBlock(text: t)
        case .tools(let es):       ToolGroup(entries: es)
        }
    }
}

struct ReaderItem: Identifiable, Sendable {
    let id: Int
    let kind: Kind
    enum Kind: Sendable {
        case user(String, Date?)
        case agent(String, Date?)
        case reasoning(String)
        case tools([ToolEntry])
    }

    static func build(from messages: [TranscriptMessage]) -> [ReaderItem] {
        var out: [ReaderItem] = []
        var run: [ToolEntry] = []
        var idx = 0
        func flush() {
            guard !run.isEmpty else { return }
            out.append(ReaderItem(id: idx, kind: .tools(run))); idx += 1; run = []
        }
        for m in messages {
            for b in m.blocks {
                switch b {
                case .text(let t):
                    flush()
                    let kind: Kind = m.role == .user ? .user(t, m.timestamp) : .agent(t, m.timestamp)
                    out.append(ReaderItem(id: idx, kind: kind)); idx += 1
                case .thinking(let t):
                    flush()
                    out.append(ReaderItem(id: idx, kind: .reasoning(t))); idx += 1
                case .toolUse(let name, let input):
                    run.append(ToolEntry(name: name, body: input, isResult: false))
                case .toolResult(let text):
                    run.append(ToolEntry(name: "result", body: text, isResult: true))
                }
            }
        }
        flush()
        return out
    }
}

struct ToolEntry: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let body: String
    let isResult: Bool
}

// MARK: - Bubble (footer right-aligned for both roles, revealed on hover)

struct ChatBubble: View {
    let text: String
    let time: Date?
    let isUser: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            // VStack sizes to the bubble; trailing alignment pins the footer to
            // the bubble's right edge (its bottom-right corner) for both roles.
            VStack(alignment: .trailing, spacing: 3) {
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(Color.primary.opacity(isUser ? 0.07 : 0.035)))
                footer.opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
            if !isUser { Spacer(minLength: 56) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let time {
                Text(time, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            CopyButton(text: text)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Reasoning (distinct from the answer)

struct ReasoningBlock: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        CollapsibleRow(expanded: $expanded) {
            Label("Reasoning", systemImage: "brain")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        } content: {
            MarkdownText(text: text)
                .font(.callout).italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
        }
    }
}

// MARK: - Tool group ("Invoked N tools" → each tool → detail)

struct ToolGroup: View {
    let entries: [ToolEntry]
    @State private var expanded = false

    private var label: String {
        let calls = entries.filter { !$0.isResult }.count
        let n = calls > 0 ? calls : entries.count
        return "Invoked \(n) tool\(n == 1 ? "" : "s")"
    }

    var body: some View {
        CollapsibleRow(expanded: $expanded, centeredLabel: true, showChevron: false) {
            Label(label, systemImage: "wrench.and.screwdriver")
                .font(.caption).foregroundStyle(.secondary)
        } content: {
            VStack(spacing: 6) {
                ForEach(entries) { ToolEntryRow(entry: $0) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No background when collapsed (less distracting); subtle when expanded.
        .background(expanded ? Color.primary.opacity(0.03) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolEntryRow: View {
    let entry: ToolEntry
    @State private var expanded = false
    var body: some View {
        CollapsibleRow(expanded: $expanded) {
            Label(entry.isResult ? "Tool result" : "Tool · \(entry.name)",
                  systemImage: entry.isResult ? "arrow.turn.down.right" : "terminal")
                .font(.caption).foregroundStyle(.secondary)
        } content: {
            CodeText(text: entry.body)
        }
    }
}

// MARK: - Reusable click-anywhere collapsible

struct CollapsibleRow<Label: View, Content: View>: View {
    @Binding var expanded: Bool
    var centeredLabel: Bool = false
    var showChevron: Bool = true
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if centeredLabel { Spacer(minLength: 0) }   // center the header
                    if showChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())   // entire row is the hit target
            }
            .buttonStyle(.plain)
            if expanded {
                content().padding(.top, 6)
            }
        }
    }
}

// MARK: - Copy

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                if copied { Text("Copied").font(.caption2) }
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Copy message")
    }
}

// MARK: - Markdown rendering (block-level)

struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {   // clear paragraph separation (was 8 — too cramped)
            ForEach(Array(MarkdownCache.blocks(text).enumerated()), id: \.offset) { idx, block in
                block.view()
                    // Headings start a new section — give them extra air above
                    // (but not the very first block).
                    .padding(.top, idx > 0 && block.isHeading ? 8 : 0)
            }
        }
        .font(.system(size: 14))   // comfortable reading base; headings/code override
        .lineSpacing(4)
    }
}

/// Memoizes the (non-trivial) block parse so a message that scrolls out of the
/// LazyVStack and back doesn't re-parse. Main-thread only (called from `body`),
/// so no locking; NSCache bounds memory and survives across sessions.
private final class BlockBox { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }

enum MarkdownCache {
    private static let cache: NSCache<NSString, BlockBox> = {
        let c = NSCache<NSString, BlockBox>()
        c.countLimit = 4000
        return c
    }()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlock.parse(text)
        cache.setObject(BlockBox(parsed), forKey: key)
        return parsed
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case code(String)
    case bullet([String])
    case ordered([(Int, String)])   // (source number, text) — preserves real numbering
    case quote(String)
    case table([[String]])   // rows of cells; first row is the header

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    @ViewBuilder
    func view() -> some View {
        switch self {
        case .paragraph(let s):
            inline(s).fixedSize(horizontal: false, vertical: true)
        case .heading(let lvl, let s):
            inline(s).font(headingFont(lvl)).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let body):
            CodeText(text: body)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(items[i]).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(items[i].0).").foregroundStyle(.secondary).monospacedDigit()
                        inline(items[i].1).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                inline(s).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                if let header = rows.first {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell).fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 21, weight: .semibold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            // table: a "| … |" row immediately followed by a |---|---| separator
            if t.contains("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushPara()
                var rows: [[String]] = [parseRow(t)]
                i += 2   // skip header + separator
                while i < lines.count {
                    let rt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rt.contains("|"), !rt.isEmpty else { break }
                    rows.append(parseRow(rt)); i += 1
                }
                blocks.append(.table(rows)); continue
            }
            if let level = headingLevel(t) {
                flushPara()
                let txt = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level, txt)); i += 1; continue
            }
            if t.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    q.append(String(s.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n"))); continue
            }
            if isBullet(t) {
                flushPara()
                var items: [String] = []
                while i < lines.count {
                    let lt = lines[i].trimmingCharacters(in: .whitespaces)
                    if isBullet(lt) { items.append(stripBullet(lt)); i += 1; continue }
                    // Loose list: a blank line between items keeps the list together
                    // (only if the next non-blank line is also a bullet).
                    if lt.isEmpty, nextNonBlankIsList(lines, from: i, ordered: false) {
                        i = skipBlanks(lines, from: i); continue
                    }
                    break
                }
                blocks.append(.bullet(items)); continue
            }
            if orderedNum(t) != nil {
                flushPara()
                var items: [(Int, String)] = []
                while i < lines.count {
                    let lt = lines[i].trimmingCharacters(in: .whitespaces)
                    if let n = orderedNum(lt) { items.append((n, stripOrdered(lt))); i += 1; continue }
                    if lt.isEmpty, nextNonBlankIsList(lines, from: i, ordered: true) {
                        i = skipBlanks(lines, from: i); continue
                    }
                    break
                }
                blocks.append(.ordered(items)); continue
            }
            if t.isEmpty { flushPara(); i += 1; continue }
            para.append(line); i += 1
        }
        flushPara()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for c in s { if c == "#" { n += 1 } else { break } }
        guard n >= 1, n <= 6, s.count > n, s[s.index(s.startIndex, offsetBy: n)] == " " else { return nil }
        return n
    }
    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }
    private static func stripBullet(_ s: String) -> String { String(s.dropFirst(2)) }
    /// Parsed leading number of an ordered-list line ("3. foo" → 3), else nil.
    private static func orderedNum(_ s: String) -> Int? {
        guard let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let num = s[s.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber),
              s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " else { return nil }
        return Int(num)
    }
    private static func skipBlanks(_ lines: [String], from i: Int) -> Int {
        var j = i
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
        return j
    }
    private static func nextNonBlankIsList(_ lines: [String], from i: Int, ordered: Bool) -> Bool {
        let j = skipBlanks(lines, from: i)
        guard j < lines.count else { return false }
        let lt = lines[j].trimmingCharacters(in: .whitespaces)
        return ordered ? (orderedNum(lt) != nil) : isBullet(lt)
    }
    private static func stripOrdered(_ s: String) -> String {
        guard let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }) else { return s }
        return String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }
    private static func isTableSeparator(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        guard stripped.contains("-") else { return false }
        return stripped.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }
    private static func parseRow(_ s: String) -> [String] {
        var cells = s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }
}

// MARK: - Code block

struct CodeText: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
