import SwiftUI

struct SettingsView: View {
    @Environment(HealthStore.self) private var health
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var health = health
        NavigationStack {
            Form {
                Section {
                    if !health.isAvailable {
                        Text("Apple Health isn't available on this device.")
                    } else if health.isConnected {
                        LabeledContent("Status", value: "Connected")
                        Toggle("Save logged food to Apple Health", isOn: $health.writesFood)
                        Button {
                            Task { await health.refresh() }
                        } label: {
                            if health.isRefreshing {
                                HStack { ProgressView(); Text("Refreshing…") }
                            } else {
                                Text("Refresh Health data")
                            }
                        }
                        if let last = health.lastRefresh {
                            LabeledContent("Last refreshed", value: last.formatted(date: .omitted, time: .shortened))
                        }
                    } else {
                        Button("Connect Apple Health") {
                            Task { await health.connect() }
                        }
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Tally reads steps, sleep, workouts, exercise minutes, water and mindful minutes, and can save the food you log. To change permissions later, open the Health app, tap your profile, then Apps.")
                }

                if let error = health.lastError {
                    Section {
                        Text(error).foregroundStyle(Theme.danger)
                        Button("Dismiss") { health.lastError = nil }
                    }
                }

                Section("Libraries") {
                    NavigationLink("Food library") { FoodLibraryView() }
                    NavigationLink("Exercise library") { ExerciseLibraryView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
