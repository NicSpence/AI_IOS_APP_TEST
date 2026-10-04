import Foundation
import SwiftData

/// Loads bundled starter data the first time the app runs.
@MainActor
enum Seeder {
    private static let seededKey = "tally.seeded.v1"

    private struct FoodSeed: Decodable {
        let name: String
        let kcal: Double
        let protein: Double?
        let carbs: Double?
        let fat: Double?
        let fiber: Double?
        let unitGrams: Double?
    }

    private struct ExerciseSeed: Decodable {
        let name: String
        let category: String?
        let muscles: String?
        let equipment: String?
    }

    static func seedIfNeeded(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        for seed in load([FoodSeed].self, from: "foods") ?? [] {
            context.insert(FoodItem(name: seed.name, kcal: seed.kcal, protein: seed.protein, carbs: seed.carbs,
                                    fat: seed.fat, fiber: seed.fiber, unitGrams: seed.unitGrams, source: "starter"))
        }
        for seed in load([ExerciseSeed].self, from: "exercises") ?? [] {
            context.insert(Exercise(name: seed.name, category: seed.category, muscles: seed.muscles,
                                    equipment: seed.equipment, source: "starter"))
        }
        for (index, goal) in starterGoals().enumerated() {
            goal.sortOrder = index
            context.insert(goal)
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            print("Seeding failed: \(error)")
        }
    }

    /// Steps and sleep come from Apple Health; food goals from the food log.
    private static func starterGoals() -> [Goal] {
        [
            Goal(title: "Train for 30 minutes", area: .fitness, kind: .amount, target: 30, unit: "min", source: .trainingMinutes),
            Goal(title: "Walk 8,000 steps", area: .fitness, kind: .amount, target: 8000, unit: "steps", source: .steps),
            Goal(title: "Hit protein target", area: .health, kind: .amount, target: 140, unit: "g", source: .protein),
            Goal(title: "Stay under calorie target", area: .health, kind: .amount, target: 2300, unit: "kcal", direction: .atMost, source: .kcal),
            Goal(title: "Sleep 7+ hours", area: .health, kind: .amount, target: 7, unit: "h", source: .sleepHours),
            Goal(title: "Drink 2.5 L water", area: .health, kind: .amount, target: 2.5, unit: "L"),
            Goal(title: "Track every expense", area: .financial, kind: .check),
            Goal(title: "No impulse purchases", area: .financial, kind: .check),
            Goal(title: "Read 20 pages", area: .cognitive, kind: .amount, target: 20, unit: "pages"),
            Goal(title: "Study for 30 minutes", area: .cognitive, kind: .amount, target: 30, unit: "min"),
        ]
    }

    private static func load<T: Decodable>(_ type: T.Type, from resource: String) -> T? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("Missing bundled \(resource).json")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            print("Couldn't read \(resource).json: \(error)")
            return nil
        }
    }
}
