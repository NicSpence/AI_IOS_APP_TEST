import Foundation
import SwiftData

// Enum-backed fields are stored as raw strings so they work in #Predicate,
// with typed computed properties for the rest of the app.
// Relationships are set *after* inserting a new object into a context.

@Model
final class Goal {
    var title: String = ""
    var areaRaw: String = GoalArea.health.rawValue
    var kindRaw: String = GoalKind.check.rawValue
    var target: Double?
    var unit: String = ""
    var directionRaw: String = Direction.atLeast.rawValue
    var sourceRaw: String = GoalSource.manual.rawValue
    var isActive: Bool = true
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \CheckIn.goal)
    var checkIns: [CheckIn] = []

    @Relationship(deleteRule: .nullify, inverse: \CoachSuggestion.goal)
    var suggestions: [CoachSuggestion] = []

    init(title: String, area: GoalArea, kind: GoalKind, target: Double? = nil, unit: String = "",
         direction: Direction = .atLeast, source: GoalSource = .manual, sortOrder: Int = 0) {
        self.title = title
        self.areaRaw = area.rawValue
        self.kindRaw = kind.rawValue
        self.target = target
        self.unit = unit
        self.directionRaw = direction.rawValue
        self.sourceRaw = source.rawValue
        self.sortOrder = sortOrder
    }

    var area: GoalArea {
        get { GoalArea(rawValue: areaRaw) ?? .health }
        set { areaRaw = newValue.rawValue }
    }
    var kind: GoalKind {
        get { GoalKind(rawValue: kindRaw) ?? .check }
        set { kindRaw = newValue.rawValue }
    }
    var direction: Direction {
        get { Direction(rawValue: directionRaw) ?? .atLeast }
        set { directionRaw = newValue.rawValue }
    }
    var source: GoalSource {
        get { GoalSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// "≥ 140 g" (or "at least 140 g" for the coach). Empty for yes/no goals.
    func targetText(words: Bool = false) -> String {
        guard kind == .amount, let target else { return "" }
        let op = words ? direction.words : direction.symbol
        let unitText = unit.isEmpty ? "" : " \(unit)"
        return "\(op) \(Fmt.num(target))\(unitText)"
    }
}

@Model
final class CheckIn {
    var day: Date = Date()
    var done: Bool = false
    var value: Double?
    var goal: Goal?

    init(day: Date, done: Bool = false, value: Double? = nil) {
        self.day = day.startOfDay
        self.done = done
        self.value = value
    }
}

/// Nutrients are per 100 g. Macros are optional because some sources only carry calories.
@Model
final class FoodItem {
    var name: String = ""
    var altName: String?
    var kcal: Double = 0
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var unitGrams: Double?
    var emoji: String?
    var source: String = "custom"
    /// 0 when protein, carbs and fat are known, 1 otherwise. Used to sort complete foods first.
    var sortRank: Int = 1

    @Relationship(deleteRule: .cascade, inverse: \FoodLog.food)
    var logs: [FoodLog] = []

    init(name: String, kcal: Double, protein: Double? = nil, carbs: Double? = nil, fat: Double? = nil,
         fiber: Double? = nil, unitGrams: Double? = nil, emoji: String? = nil, source: String = "custom") {
        self.name = name
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.unitGrams = unitGrams
        self.emoji = emoji
        self.source = source
        updateRank()
    }

    var macrosKnown: Bool { protein != nil && carbs != nil && fat != nil }

    func updateRank() { sortRank = macrosKnown ? 0 : 1 }
}

@Model
final class FoodLog {
    var day: Date = Date()
    var mealRaw: String = Meal.snack.rawValue
    var grams: Double = 0
    var createdAt: Date = Date()
    /// Tags the matching samples in Apple Health so they can be deleted with this entry.
    var syncID: UUID = UUID()
    var food: FoodItem?

    init(day: Date, meal: Meal, grams: Double) {
        self.day = day.startOfDay
        self.mealRaw = meal.rawValue
        self.grams = grams
    }

    var meal: Meal { Meal(rawValue: mealRaw) ?? .snack }

    private func scaled(_ per100: Double?) -> Double? { per100.map { $0 * grams / 100 } }
    var kcal: Double? { food.map { $0.kcal * grams / 100 } }
    var protein: Double? { scaled(food?.protein) }
    var carbs: Double? { scaled(food?.carbs) }
    var fat: Double? { scaled(food?.fat) }
    var fiber: Double? { scaled(food?.fiber) }
}

@Model
final class Exercise {
    var name: String = ""
    var category: String?
    var muscles: String?
    var equipment: String?
    var details: String?
    var source: String = "custom"
    var externalID: String?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutLog.exercise)
    var logs: [WorkoutLog] = []

    init(name: String, category: String? = nil, muscles: String? = nil, equipment: String? = nil,
         details: String? = nil, source: String = "custom", externalID: String? = nil) {
        self.name = name
        self.category = category
        self.muscles = muscles
        self.equipment = equipment
        self.details = details
        self.source = source
        self.externalID = externalID
    }
}

@Model
final class WorkoutLog {
    var day: Date = Date()
    var sets: Int?
    var reps: Int?
    var weightKg: Double?
    var minutes: Double?
    var notes: String = ""
    var createdAt: Date = Date()
    var exercise: Exercise?

    init(day: Date, sets: Int? = nil, reps: Int? = nil, weightKg: Double? = nil, minutes: Double? = nil, notes: String = "") {
        self.day = day.startOfDay
        self.sets = sets
        self.reps = reps
        self.weightKg = weightKg
        self.minutes = minutes
        self.notes = notes
    }

    /// "Back squat 4x5 @ 100 kg 20 min"
    var summary: String {
        var parts = [exercise?.name ?? "Exercise"]
        if let sets, let reps { parts.append("\(sets)x\(reps)") } else if let sets { parts.append("\(sets) sets") }
        if let weightKg { parts.append("@ \(Fmt.num(weightKg)) kg") }
        if let minutes { parts.append("\(Fmt.num(minutes)) min") }
        return parts.joined(separator: " ")
    }
}

@Model
final class Note {
    var day: Date = Date()
    var body: String = ""
    var createdAt: Date = Date()

    init(day: Date, body: String) {
        self.day = day.startOfDay
        self.body = body
    }
}

@Model
final class CoachReport {
    var createdAt: Date = Date()
    var startDay: Date = Date()
    var endDay: Date = Date()
    var summary: String = ""
    var wins: [String] = []
    var concerns: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \CoachSuggestion.report)
    var suggestions: [CoachSuggestion] = []

    init(startDay: Date, endDay: Date, summary: String, wins: [String], concerns: [String]) {
        self.startDay = startDay
        self.endDay = endDay
        self.summary = summary
        self.wins = wins
        self.concerns = concerns
    }

    /// Relationship arrays are unordered in SwiftData.
    var orderedSuggestions: [CoachSuggestion] { suggestions.sorted { $0.order < $1.order } }
}

@Model
final class CoachSuggestion {
    var kindRaw: String = SuggestionKind.tip.rawValue
    var statusRaw: String = SuggestionStatus.pending.rawValue
    var title: String = ""
    var areaRaw: String?
    var target: Double?
    var unit: String?
    var reason: String = ""
    var previousTarget: Double?
    var resolvedAt: Date?
    var order: Int = 0
    var goal: Goal?
    var report: CoachReport?

    init(kind: SuggestionKind, title: String, area: GoalArea?, target: Double?, unit: String?, reason: String, order: Int) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.areaRaw = area?.rawValue
        self.target = target
        self.unit = unit
        self.reason = reason
        self.order = order
    }

    var kind: SuggestionKind { SuggestionKind(rawValue: kindRaw) ?? .tip }
    var status: SuggestionStatus {
        get { SuggestionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
    var area: GoalArea? { areaRaw.flatMap(GoalArea.init(rawValue:)) }
}
