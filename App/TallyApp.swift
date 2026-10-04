import SwiftUI
import SwiftData

@main
struct TallyApp: App {
    private let container: ModelContainer
    @State private var health = HealthStore()
    @State private var coach = CoachService()

    init() {
        do {
            container = try ModelContainer(
                for: Goal.self, CheckIn.self, FoodItem.self, FoodLog.self, Exercise.self,
                WorkoutLog.self, Note.self, CoachReport.self, CoachSuggestion.self
            )
        } catch {
            fatalError("Couldn't open the Tally database: \(error)")
        }
        Seeder.seedIfNeeded(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(health)
                .environment(coach)
        }
        .modelContainer(container)
    }
}
