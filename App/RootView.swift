import SwiftUI

struct RootView: View {
    @Environment(HealthStore.self) private var health
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Today", systemImage: "checklist") { TodayView() }
            Tab("Food", systemImage: "fork.knife") { FoodView() }
            Tab("Training", systemImage: "dumbbell") { TrainingView() }
            Tab("Goals", systemImage: "target") { GoalsView() }
            Tab("Coach", systemImage: "sparkles") { CoachView() }
        }
        .task { await health.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await health.refresh() }
            }
        }
    }
}
