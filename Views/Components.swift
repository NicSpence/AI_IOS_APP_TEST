import SwiftUI
import UIKit

// MARK: Theme
// Colour is reserved for the four goal areas; everything else stays neutral.

enum Theme {
    static let ink = Color(light: 0x17212B, dark: 0xE6EBF0)
    static let danger = Color(light: 0xB42318, dark: 0xFF8A7A)
}

extension GoalArea {
    var color: Color {
        switch self {
        case .fitness: Color(light: 0xD1495B, dark: 0xF07A88)
        case .health: Color(light: 0x1F8A7E, dark: 0x4CC3B4)
        case .financial: Color(light: 0xA87C00, dark: 0xD9AE2E)
        case .cognitive: Color(light: 0x5654C9, dark: 0x8F8DF2)
        }
    }

    var symbol: String {
        switch self {
        case .fitness: "figure.run"
        case .health: "heart"
        case .financial: "banknote"
        case .cognitive: "book"
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    /// nonisolated because UIKit calls dynamic color providers outside the main actor.
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: Day stepper

struct DayStepper: View {
    @Binding var day: Date

    var body: some View {
        HStack {
            Button {
                day = day.adding(days: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous day")

            Spacer()
            VStack(spacing: 2) {
                Text(day.isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                    .font(.headline)
                Text(day.formatted(.dateTime.day().month(.wide).year()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .onTapGesture { day = Date().startOfDay }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to go back to today")
            Spacer()

            Button {
                day = day.adding(days: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(day >= Date().startOfDay)
            .accessibilityLabel("Next day")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: Goal pieces

struct Tick: View {
    let met: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 2)
            if met {
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }
}

struct ProgressBar: View {
    let progress: Double
    let color: Color
    var over = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(over ? Theme.danger : color)
                    .frame(width: geo.size.width * max(0, min(progress, 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// One square per day, oldest on the left. Filled = met, outlined = missed, faint = nothing logged.
struct StreakStrip: View {
    let statuses: [GoalStatus]
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { index, status in
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.met == true ? color : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(borderColor(for: status), lineWidth: 1.5)
                    }
                    .frame(width: 10, height: 10)
                    .padding(1.5)
                    .overlay {
                        if index == statuses.count - 1 {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.ink, lineWidth: 1)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Met on \(statuses.filter { $0.met == true }.count) of the last \(statuses.count) days")
    }

    private func borderColor(for status: GoalStatus) -> Color {
        switch status.met {
        case true?: color
        case false?: color.opacity(0.55)
        case nil: Color.secondary.opacity(0.3)
        }
    }
}

struct AreaDot: View {
    let area: GoalArea
    var body: some View {
        Circle().fill(area.color).frame(width: 10, height: 10).accessibilityHidden(true)
    }
}

/// Big number with a small label, used for food totals.
struct StatTile: View {
    let label: String
    let value: String
    let unit: String
    var target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if let target {
                Text("target \(target)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
