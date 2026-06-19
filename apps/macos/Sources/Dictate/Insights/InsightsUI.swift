import SwiftUI
import AppKit

/// The Insights dashboard shell: a Flow-style dark sidebar (Home / Insights / Dictionary / History)
/// over a detail pane. Phase 1 wires Home to real stats; the others are honest placeholders.
struct InsightsRootView: View {
    @ObservedObject var store: InsightStore
    @State private var section: Section = .home

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case home = "Home", insights = "Insights", dictionary = "Dictionary", history = "History"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "square.grid.2x2"
            case .insights: return "chart.bar"
            case .dictionary: return "character.book.closed"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(VozTheme.electric)
                    Text("voz").font(.headline).foregroundStyle(VozTheme.textHi)
                    Text("Insights").font(.headline).foregroundStyle(VozTheme.mist)
                }
                .padding(.vertical, 8)

                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch section {
                case .home: HomeView(store: store)
                case .insights: ComingSoon(icon: "chart.bar",
                                           title: "Insights",
                                           subtitle: "Words per day, WPM over time, and where you dictate most.")
                case .dictionary: ComingSoon(icon: "character.book.closed",
                                             title: "Dictionary",
                                             subtitle: "Your learned spellings & pronunciations, redesigned here. For now: menu → Dictionary…")
                case .history: ComingSoon(icon: "clock.arrow.circlepath",
                                          title: "History",
                                          subtitle: "A searchable feed of every dictation — the text, the app it went into, when.")
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .background(VozTheme.black)
        }
        .preferredColorScheme(.dark)
    }
}

/// Home: the locked must-have stat cards + a recent feed.
struct HomeView: View {
    @ObservedObject var store: InsightStore

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Welcome back, \(firstName)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(VozTheme.textHi)

                HStack(spacing: 16) {
                    StatCard(value: store.totalWordsCompact, label: "total words")
                    StatCard(value: "\(store.avgWPM)", label: "wpm")
                    StatCard(value: "\(store.dayStreak)", label: store.dayStreak == 1 ? "day streak" : "day streak")
                }

                if store.events.isEmpty {
                    EmptyHome()
                } else {
                    Text("Recent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VozTheme.mist)
                        .textCase(.uppercase)
                    VStack(spacing: 0) {
                        ForEach(store.events.suffix(8).reversed()) { e in
                            RecentRow(event: e)
                            if e.id != store.events.suffix(8).reversed().last?.id {
                                Divider().overlay(VozTheme.line)
                            }
                        }
                    }
                    .background(VozTheme.ink, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(VozTheme.line, lineWidth: 1))
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VozTheme.black)
    }
}

struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(VozTheme.textHi)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(VozTheme.mist)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VozTheme.ink, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(VozTheme.line, lineWidth: 1))
    }
}

private struct RecentRow: View {
    let event: DictationEvent
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.time.string(from: event.date))
                .font(.system(size: 12))
                .foregroundStyle(VozTheme.mist)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.text.isEmpty ? "\(event.words) words" : event.text)
                    .font(.system(size: 13))
                    .foregroundStyle(VozTheme.textHi)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let app = event.appName {
                        Text(app).font(.system(size: 11)).foregroundStyle(VozTheme.electric)
                    }
                    Text("· \(event.words) words · \(event.wpm) wpm")
                        .font(.system(size: 11))
                        .foregroundStyle(VozTheme.mist)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct EmptyHome: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic").font(.system(size: 28)).foregroundStyle(VozTheme.electric)
            Text("Hold ⌃⌥ and start dictating — your words, streak, and WPM build up here.")
                .font(.system(size: 13))
                .foregroundStyle(VozTheme.mist)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(VozTheme.ink, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VozTheme.line, lineWidth: 1))
    }
}

struct ComingSoon: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(VozTheme.electric)
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(VozTheme.textHi)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(VozTheme.mist)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Coming soon").font(.system(size: 11, weight: .semibold)).foregroundStyle(VozTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
