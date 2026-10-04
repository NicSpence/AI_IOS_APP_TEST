import Foundation

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    var isToday: Bool { Calendar.current.isDateInToday(self) }

    /// "Saturday, 3 October"
    var longDay: String { formatted(.dateTime.weekday(.wide).day().month(.wide)) }

    /// "Sat 3 Oct"
    var shortDay: String { formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }

    /// "2026-10-03" in the local calendar, for the coach prompt.
    var isoDay: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

enum Days {
    /// `count` calendar days ending on `end`, oldest first.
    static func ending(on end: Date, count: Int) -> [Date] {
        let last = end.startOfDay
        return (0..<count).reversed().map { last.adding(days: -$0) }
    }
}

enum Fmt {
    /// 1,394 / 85.8 / 7 / "—". Values of 100 or more drop decimals.
    static func num(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        if abs(value - value.rounded()) < 1e-9 || abs(value) >= 100 {
            return Int(value.rounded()).formatted()
        }
        return value.formatted(.number.precision(.fractionLength(0...decimals)))
    }

    /// For pre-filling text fields: no grouping separators, up to two decimals.
    static func plain(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// Parses user input. Accepts "2.5", "2,5", "8000" and "8,000".
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if s.contains(",") && s.contains(".") {
            s = s.replacingOccurrences(of: ",", with: "")
        } else if s.contains(",") {
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            let looksLikeThousands = parts.count > 1 && parts.dropFirst().allSatisfy { $0.count == 3 }
            s = s.replacingOccurrences(of: ",", with: looksLikeThousands ? "" : ".")
        }
        return Double(s)
    }
}
