import SwiftUI
import Charts

/// Texte der Hör-Statistik
enum StatsText {
    /// Hörzeit: „42 Min.“ bzw. „19 Std., 4 Min.“ (Stunden laufen weiter, keine Tage)
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds), h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(localized: "\(h) Std., \(m) Min.") : String(localized: "\(m) Min.")
    }
}

/// Minuten je Tag
struct StatsDailyChart: View {
    let days: [(day: Date, seconds: Double)]
    /// 7 Tage: jeder Wochentag beschriftet; sonst ein Strich je Woche
    let week: Bool

    var body: some View {
        Chart(days, id: \.day) { d in
            BarMark(x: .value("Tag", d.day, unit: .day), y: .value("Minuten", d.seconds / 60))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .day, count: week ? 1 : 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxisLabel { Text("Minuten") }
    }
}

/// Minuten je Uhrzeit (0–23 Uhr)
struct StatsHoursChart: View {
    let hours: [Double]

    var body: some View {
        Chart(Array(hours.enumerated()), id: \.offset) { h in
            RectangleMark(xStart: .value("Uhrzeit", Double(h.offset) - 0.35), xEnd: .value("Uhrzeit", Double(h.offset) + 0.35),
                          yStart: .value("Minuten", 0), yEnd: .value("Minuten", h.element / 60))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(preset: .aligned, values: [0, 6, 12, 18, 23]) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Int.self) { Text(verbatim: "\(h)") } }
            }
        }
        .chartYAxisLabel { Text("Minuten") }
    }
}
