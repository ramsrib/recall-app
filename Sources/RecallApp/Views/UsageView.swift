import SwiftUI
import Charts

/// Full-window usage dashboard, driven by the `ccusage` CLI and joined with
/// recall's session→project map. Token-focused (cost shown as a secondary line),
/// from the app's perspective: where your tokens go by project and agent.
struct UsageView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: UsageModel       // owned by AppState → persists across open/close
    @State private var span: TrendSpan = .daily

    enum TrendSpan: String, CaseIterable, Identifiable { case daily = "Daily", weekly = "Weekly"; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let err = model.error {
                    errorState(err)
                } else if model.loading && !model.loaded {
                    ProgressView("Loading usage…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    pageHeader
                    summaryCards
                    trendSection
                    projectSection
                    agentSection
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.never)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Usage")
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Mirror OmniBar (two-line block + same padding + maxWidth) so the
                // title reads consistently with the session pages.
                VStack(spacing: 2) {
                    Text("Usage")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(model.loaded ? "\(model.projects.count) projects · \(model.agents.count) agents"
                                      : "Token & cost usage")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: 460)
            }
            // No toolbar refresh: this 3-col NavigationSplitView can't place a
            // button beside the content-column `.searchable` field (detail actions
            // land mid-bar, content actions land far-left). The refresh lives in
            // the page content instead — predictable and reads as intentional.
        }
        .task {
            // The project join needs recall's session→project map; make sure
            // it's loaded before fetching/joining usage.
            if app.sessions.isEmpty { await app.load() }
            await model.load(sessions: app.sessions)
        }
    }

    // MARK: Header (in-content refresh)

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionLabel("Overview")
            Spacer()
            Button { Task { await model.load(sessions: app.sessions, force: true) } } label: {
                Label(model.loading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.loading)
            .help("Reload usage data from ccusage")
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        // Adaptive grid so the cards stay readable whether the detail column is
        // narrow (list visible) or wide.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            StatCard(title: "Today",
                     value: UsageFormat.tokens(model.today?.totalTokens ?? 0),
                     caption: UsageFormat.cost(model.today?.totalCost ?? 0))
            StatCard(title: "This Month",
                     value: UsageFormat.tokens(model.monthTokens),
                     caption: UsageFormat.cost(model.monthCost))
            StatCard(title: "All Time",
                     value: UsageFormat.tokens(model.totals?.totalTokens ?? 0),
                     caption: UsageFormat.cost(model.totals?.totalCost ?? 0))
            StatCard(title: "Generated",
                     value: UsageFormat.tokens((model.totals?.inputTokens ?? 0) + (model.totals?.outputTokens ?? 0)),
                     caption: "input + output (excl. cache)")
        }
    }

    // MARK: Trend

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Token Activity")
                Spacer()
                Picker("", selection: $span) {
                    ForEach(TrendSpan.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            let points = span == .daily ? model.dailyPoints : model.weeklyPoints
            if points.isEmpty {
                emptyHint("No activity in range.")
            } else {
                Chart(points) { p in
                    BarMark(
                        x: .value("Date", p.date, unit: span == .daily ? .day : .weekOfYear),
                        y: .value("Tokens", p.tokens)
                    )
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Color.hairline)
                        AxisValueLabel {
                            if let v = value.as(Int.self) { Text(UsageFormat.tokens(v)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(Color.hairline.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 220)
            }
        }
    }

    // MARK: Projects (the app's perspective)

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Tokens by Project")
            if model.projects.isEmpty {
                emptyHint("No project usage matched.")
            } else {
                let top = Array(model.projects.prefix(10))
                let maxTokens = top.first?.tokens ?? 1
                VStack(spacing: 0) {
                    ForEach(top) { p in
                        ProjectBar(usage: p, fraction: Double(p.tokens) / Double(max(maxTokens, 1)))
                    }
                }
                if model.unmatchedTokens > 0 {
                    Text("\(UsageFormat.tokens(model.unmatchedTokens)) tokens from sessions not in the index (other agents / pruned).")
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
        }
    }

    // MARK: Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("By Agent")
            if model.agents.isEmpty {
                emptyHint("No agent usage.")
            } else {
                let total = max(model.agents.reduce(0) { $0 + $1.tokens }, 1)
                HStack(spacing: 14) {
                    ForEach(model.agents) { a in
                        AgentCard(usage: a, share: Double(a.tokens) / Double(total))
                    }
                }
            }
        }
    }

    // MARK: Bits

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Retry") { Task { await model.load(sessions: app.sessions, force: true) } }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Components

private struct StatCard: View {
    let title: String
    let value: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }
}

private struct ProjectBar: View {
    let usage: ProjectUsage
    let fraction: Double
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(usage.name).font(.system(size: 13)).lineLimit(1)
                Text("· \(usage.sessions) session\(usage.sessions == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(UsageFormat.tokens(usage.tokens)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(UsageFormat.cost(usage.cost)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .trailing).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06)).frame(height: 6)
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: max(4, geo.size.width * fraction), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().overlay(Color.hairline) }
    }
}

private struct AgentCard: View {
    let usage: AgentUsage
    let share: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(usage.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int((share * 100).rounded()))%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(UsageFormat.tokens(usage.tokens)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(UsageFormat.cost(usage.cost)).font(.system(size: 11)).foregroundStyle(.tertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06)).frame(height: 5)
                    Capsule().fill(Color.primary.opacity(0.5))
                        .frame(width: max(4, geo.size.width * share), height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }
}
