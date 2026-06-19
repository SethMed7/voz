import SwiftUI
import AppKit

/// The searchable, per-app-filterable feed of every dictation. Tap one to open it: replay the saved
/// recording, fix the text, and teach the dictionary.
struct HistoryView: View {
    @ObservedObject var store: InsightStore
    @State private var search = ""
    @State private var appFilter: String? = nil

    private var rows: [DictationEvent] {
        store.events.reversed().filter(matches)
    }
    private func matches(_ e: DictationEvent) -> Bool {
        if let f = appFilter, (e.appBundleId ?? e.appName ?? "Unknown") != f { return false }
        if search.isEmpty { return true }
        return e.text.localizedCaseInsensitiveContains(search)
            || (e.appName ?? "").localizedCaseInsensitiveContains(search)
    }
    private var filterLabel: String {
        appFilter.flatMap { k in store.appFilters.first { $0.key == k }?.name } ?? "All apps"
    }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: DictationEvent.self) { e in
                    DictationDetailView(store: store, event: e)
                }
                .searchable(text: $search, placement: .toolbar, prompt: "Search dictations")
                .toolbar { filterToolbar }
        }
        .background(VozTheme.black)
    }

    @ViewBuilder private var content: some View {
        if store.events.isEmpty {
            ComingSoon(icon: "clock.arrow.circlepath", title: "No dictations yet",
                       subtitle: "Hold ⌃⌥ and speak — each dictation shows up here with its recording.")
        } else {
            List {
                ForEach(rows) { e in
                    NavigationLink(value: e) { HistoryRow(store: store, event: e) }
                        .listRowBackground(VozTheme.ink)
                }
            }
            .scrollContentBackground(.hidden)
            .background(VozTheme.black)
        }
    }

    @ToolbarContentBuilder private var filterToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("All apps") { appFilter = nil }
                if !store.appFilters.isEmpty { Divider() }
                ForEach(store.appFilters, id: \.key) { f in
                    Button(f.name) { appFilter = f.key }
                }
            } label: {
                Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

struct HistoryRow: View {
    @ObservedObject var store: InsightStore
    let event: DictationEvent
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleId: event.appBundleId)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.text.isEmpty ? "\(event.words) words" : event.text)
                    .font(.system(size: 13)).foregroundStyle(VozTheme.textHi).lineLimit(1)
                HStack(spacing: 6) {
                    Text(event.appName ?? "—").foregroundStyle(VozTheme.electric)
                    Text("· \(RelTime.string(event.date)) · \(event.words) words").foregroundStyle(VozTheme.mist)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if store.audioURL(for: event) != nil {
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(VozTheme.mist)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The opened dictation: replay, correct the text, and teach the dictionary.
struct DictationDetailView: View {
    @ObservedObject var store: InsightStore
    let event: DictationEvent
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = AudioPlayer()
    @State private var editedText: String
    @State private var heard = ""
    @State private var correct = ""
    @State private var note = ""

    init(store: InsightStore, event: DictationEvent) {
        self.store = store
        self.event = event
        _editedText = State(initialValue: event.text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    AppIconView(bundleId: event.appBundleId, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.appName ?? "Dictation").font(.system(size: 16, weight: .semibold)).foregroundStyle(VozTheme.textHi)
                        Text("\(RelTime.string(event.date)) · \(event.words) words · \(event.wpm) wpm · \(event.engine)")
                            .font(.system(size: 11)).foregroundStyle(VozTheme.mist)
                    }
                    Spacer()
                }

                if let url = store.audioURL(for: event) {
                    HStack(spacing: 12) {
                        Button { audio.toggle(url) } label: {
                            Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30)).foregroundStyle(VozTheme.electric)
                        }
                        .buttonStyle(.plain)
                        ProgressView(value: audio.progress).tint(VozTheme.electric)
                        Text("recording").font(.system(size: 11)).foregroundStyle(VozTheme.mist)
                    }
                    .padding(12)
                    .background(VozTheme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VozTheme.line, lineWidth: 1))
                } else {
                    Text("No saved recording for this one.").font(.system(size: 12)).foregroundStyle(VozTheme.mist)
                }

                section("Transcript")
                TextEditor(text: $editedText)
                    .font(.system(size: 14))
                    .foregroundStyle(VozTheme.textHi)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(VozTheme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VozTheme.line, lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Save text") { store.updateText(event.id, to: editedText); note = "Saved." }
                        .disabled(editedText == event.text)
                }

                section("Teach the dictionary")
                Text("Heard a word wrong? Add the fix so future dictations get it right — that's how you train it.")
                    .font(.system(size: 12)).foregroundStyle(VozTheme.mist)
                HStack(spacing: 8) {
                    TextField("voz heard…", text: $heard).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(VozTheme.mist)
                    TextField("should be…", text: $correct).textFieldStyle(.roundedBorder)
                    Button("Add") { addCorrection() }.disabled(heard.isEmpty || correct.isEmpty)
                }
                if !note.isEmpty {
                    Text(note).font(.system(size: 12)).foregroundStyle(VozTheme.electric)
                }

                Divider().overlay(VozTheme.line).padding(.top, 8)
                Button(role: .destructive) {
                    audio.stop(); store.delete(event); dismiss()
                } label: {
                    Label("Delete this dictation", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VozTheme.black)
        .onDisappear { audio.stop() }
    }

    private func addCorrection() {
        let from = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return }
        Lexicon.shared.learnExplicit(from: from, to: to)
        note = "Added “\(from)” → “\(to)” to your dictionary."
        heard = ""; correct = ""
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(VozTheme.mist).textCase(.uppercase)
    }
}

/// Small app icon resolved from a bundle id (falls back to a glyph once the app has quit).
struct AppIconView: View {
    let bundleId: String?
    var size: CGFloat = 22
    var body: some View {
        if let img = Self.icon(bundleId) {
            Image(nsImage: img).resizable().frame(width: size, height: size).cornerRadius(size * 0.22)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.8))
                .foregroundStyle(VozTheme.mist).frame(width: size, height: size)
        }
    }
    static func icon(_ bundleId: String?) -> NSImage? {
        guard let b = bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum RelTime {
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    static func string(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? time.string(from: date) : rel.localizedString(for: date, relativeTo: Date())
    }
}
