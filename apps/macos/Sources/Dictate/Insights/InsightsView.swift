import SwiftUI
import Charts

/// The Insights charts — words per day, speaking pace (WPM), and per-app usage. All derived from the
/// local store, single electric-blue hue (no rainbow), dark axes.
struct InsightsView: View {
    @ObservedObject var store: InsightStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Insights").font(.system(size: 26, weight: .bold)).foregroundStyle(VozTheme.textHi)
                if store.dictations.isEmpty {
                    ComingSoon(icon: "chart.bar", title: "No data yet",
                               subtitle: "Dictate a few times and your trends show up here.")
                } else {
                    wordsCard
                    wpmCard
                    perAppCard
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VozTheme.black)
    }

    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Words per day", "Last 30 days")
            Chart(store.wordsPerDay) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Words", d.value), width: .fixed(6))
                    .foregroundStyle(VozTheme.electric)
                    .cornerRadius(2)
            }
            .frame(height: 170)
            .chartXAxis { dayAxis }
            .chartYAxis { valueAxis }
        }
        .cardStyle()
    }

    private var wpmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Speaking pace", "Words per minute, by day")
            Chart(store.wpmPerDay) { d in
                AreaMark(x: .value("Day", d.date, unit: .day), y: .value("WPM", d.value))
                    .foregroundStyle(LinearGradient(colors: [VozTheme.electric.opacity(0.30), VozTheme.electric.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Day", d.date, unit: .day), y: .value("WPM", d.value))
                    .foregroundStyle(VozTheme.electric)
                    .interpolationMethod(.catmullRom)
            }
            .frame(height: 170)
            .chartXAxis { dayAxis }
            .chartYAxis { valueAxis }
        }
        .cardStyle()
    }

    private var perAppCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Where you dictate", "Words by app")
            Chart(Array(store.perApp.prefix(8))) { app in
                BarMark(x: .value("Words", app.words), y: .value("App", app.name))
                    .foregroundStyle(VozTheme.electric)
                    .cornerRadius(3)
            }
            .frame(height: CGFloat(min(8, max(1, store.perApp.count)) * 32 + 24))
            .chartXAxis { valueAxis }
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(VozTheme.mist).font(.system(size: 11)) }
            }
        }
        .cardStyle()
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(VozTheme.textHi)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(VozTheme.mist)
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(VozTheme.line.opacity(0.6))
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(VozTheme.mist).font(.system(size: 10))
        }
    }
    private var valueAxis: some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(VozTheme.line.opacity(0.5))
            AxisValueLabel().foregroundStyle(VozTheme.mist).font(.system(size: 10))
        }
    }
}
