import Foundation
import SwiftData

typealias HealthSnapshot = [Date: [HealthMetric: Double]]

struct NutritionTotals {
    var kcal = 0.0
    var protein = 0.0
    var carbs = 0.0
    var fat = 0.0
    var fiber = 0.0
    var items = 0
    var missingMacros = 0

    func value(for source: GoalSource) -> Double? {
        switch source {
        case .kcal: return kcal
        case .protein: return protein
        case .carbs: return carbs
        case .fat: return fat
        case .fiber: return fiber
        default: return nil
        }
    }
}

struct TrainingTotals {
    var minutes = 0.0
    var sets = 0
    var entries: [WorkoutLog] = []
}

struct GoalStatus {
    let day: Date
    let value: Double?
    /// true = met, false = missed, nil = nothing logged
    let met: Bool?
    let progress: Double
    let over: Bool

    static func empty(_ day: Date) -> GoalStatus {
        GoalStatus(day: day, value: nil, met: nil, progress: 0, over: false)
    }
}

/// Everything needed to evaluate goals over a range of days, keyed by start-of-day.
struct DayData {
    var nutrition: [Date: NutritionTotals] = [:]
    var training: [Date: TrainingTotals] = [:]
    var checks: [PersistentIdentifier: [Date: CheckIn]] = [:]
    var health: HealthSnapshot = [:]

    init(foodLogs: [FoodLog], workoutLogs: [WorkoutLog], checkIns: [CheckIn], health: HealthSnapshot) {
        for log in foodLogs {
            guard let food = log.food else { continue }
            let day = log.day.startOfDay
            let factor = log.grams / 100
            var t = nutrition[day, default: NutritionTotals()]
            t.items += 1
            t.kcal += food.kcal * factor
            if let v = food.protein { t.protein += v * factor }
            if let v = food.carbs { t.carbs += v * factor }
            if let v = food.fat { t.fat += v * factor }
            if let v = food.fiber { t.fiber += v * factor }
            if !food.macrosKnown { t.missingMacros += 1 }
            nutrition[day] = t
        }
        for log in workoutLogs.sorted(by: { $0.createdAt < $1.createdAt }) {
            let day = log.day.startOfDay
            var t = training[day, default: TrainingTotals()]
            t.minutes += log.minutes ?? 0
            t.sets += log.sets ?? 0
            t.entries.append(log)
            training[day] = t
        }
        for check in checkIns {
            guard let goal = check.goal else { continue }
            checks[goal.persistentModelID, default: [:]][check.day.startOfDay] = check
        }
        self.health = health
    }

    func checkIn(for goal: Goal, on day: Date) -> CheckIn? {
        checks[goal.persistentModelID]?[day.startOfDay]
    }
}

enum Tracker {
    static func evaluate(_ goal: Goal, on day: Date, data: DayData) -> GoalStatus {
        let day = day.startOfDay
        let check = data.checkIn(for: goal, on: day)

        if goal.kind == .check {
            let met: Bool? = check.map { $0.done }
            return GoalStatus(day: day, value: nil, met: met, progress: met == true ? 1 : 0, over: false)
        }

        let value: Double?
        switch goal.source.group {
        case .manual:
            value = check?.value
        case .food:
            value = data.nutrition[day]?.value(for: goal.source)
        case .training:
            if let t = data.training[day] {
                value = goal.source == .trainingSets ? Double(t.sets) : t.minutes
            } else {
                value = nil
            }
        case .health:
            if let metric = goal.source.healthMetric {
                value = data.health[day]?[metric]
            } else {
                value = nil
            }
        }

        guard let value else { return .empty(day) }
        guard let target = goal.target, target > 0 else {
            return GoalStatus(day: day, value: value, met: value > 0, progress: value > 0 ? 1 : 0, over: false)
        }
        let progress = min(value / target, 1)
        if goal.direction == .atMost {
            let met = value <= target
            return GoalStatus(day: day, value: value, met: met, progress: progress, over: !met)
        }
        return GoalStatus(day: day, value: value, met: value >= target, progress: progress, over: false)
    }

    static func history(_ goal: Goal, days: [Date], data: DayData) -> [GoalStatus] {
        days.map { evaluate(goal, on: $0, data: data) }
    }

    /// (days met, days with an entry, total days)
    static func hitRate(_ goal: Goal, days: [Date], data: DayData) -> (met: Int, logged: Int, total: Int) {
        let statuses = history(goal, days: days, data: data)
        return (statuses.filter { $0.met == true }.count, statuses.filter { $0.met != nil }.count, statuses.count)
    }

    /// Goals in display order: by area, then the user's order.
    static func ordered(_ goals: [Goal]) -> [Goal] {
        let areaOrder = Dictionary(uniqueKeysWithValues: GoalArea.allCases.enumerated().map { ($1, $0) })
        return goals.sorted {
            let a = areaOrder[$0.area] ?? 0, b = areaOrder[$1.area] ?? 0
            return a != b ? a < b : $0.sortOrder < $1.sortOrder
        }
    }
}
