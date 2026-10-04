import Foundation

enum GoalArea: String, CaseIterable, Identifiable, Codable {
    case fitness, health, financial, cognitive
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum GoalKind: String, CaseIterable, Identifiable {
    case check, amount
    var id: String { rawValue }
    var label: String { self == .check ? "Yes / no" : "Amount" }
}

enum Direction: String, CaseIterable, Identifiable {
    case atLeast, atMost
    var id: String { rawValue }
    var label: String { self == .atLeast ? "At or above target" : "At or below target" }
    var symbol: String { self == .atLeast ? "≥" : "≤" }
    var words: String { self == .atLeast ? "at least" : "at most" }
}

/// Where an amount goal gets its daily value from.
/// Raw values of the Apple Health cases must match `HealthMetric`.
enum GoalSource: String, CaseIterable, Identifiable {
    case manual
    case kcal, protein, carbs, fat, fiber
    case trainingMinutes, trainingSets
    case steps, sleepHours, exerciseMinutes, workoutMinutes, waterLiters, mindfulMinutes, activeEnergy

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case manual = "Entered by you"
        case food = "Food log"
        case training = "Training log"
        case health = "Apple Health"
    }

    var group: Group {
        switch self {
        case .manual: .manual
        case .kcal, .protein, .carbs, .fat, .fiber: .food
        case .trainingMinutes, .trainingSets: .training
        default: .health
        }
    }

    var label: String {
        switch self {
        case .manual: "I'll enter it"
        case .kcal: "Calories eaten"
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        case .fiber: "Fiber"
        case .trainingMinutes: "Training minutes"
        case .trainingSets: "Training sets"
        case .steps: "Steps"
        case .sleepHours: "Hours asleep"
        case .exerciseMinutes: "Exercise minutes (ring)"
        case .workoutMinutes: "Workout minutes"
        case .waterLiters: "Water"
        case .mindfulMinutes: "Mindful minutes"
        case .activeEnergy: "Active calories"
        }
    }

    var defaultUnit: String {
        switch self {
        case .manual: ""
        case .kcal, .activeEnergy: "kcal"
        case .protein, .carbs, .fat, .fiber: "g"
        case .trainingMinutes, .exerciseMinutes, .workoutMinutes, .mindfulMinutes: "min"
        case .trainingSets: "sets"
        case .steps: "steps"
        case .sleepHours: "h"
        case .waterLiters: "L"
        }
    }

    var healthMetric: HealthMetric? { HealthMetric(rawValue: rawValue) }

    /// Short phrase used in the UI and in the coach prompt.
    var origin: String {
        switch group {
        case .manual: "entered by you"
        case .food: "from food log"
        case .training: "from training log"
        case .health: "from Apple Health"
        }
    }
}

enum Meal: String, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// A sensible default for "what am I logging right now".
    static var current: Meal {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 17..<22: .dinner
        default: .snack
        }
    }
}

enum SuggestionKind: String {
    case adjustTarget, newGoal, pauseGoal, tip
}

enum SuggestionStatus: String {
    case pending, accepted, dismissed, ignored
}
