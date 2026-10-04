import SwiftUI
import SwiftData

struct TodayView: View {
    @State private var day = Date().startOfDay
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            DayBoard(day: day, selectedDay: $day)
                .id(day)
                .navigationTitle("Tally")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

/// The checklist for one day. Re-created when the day changes so its queries cover the right range.
private struct DayBoard: View {
    let day: Date
    @Binding var selectedDay: Date

    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health

    @Query(filter: #Predicate<Goal> { $0.isActive == true }) private var goals: [Goal]
    @Query private var checkIns: [CheckIn]
    @Query private var foodLogs: [FoodLog]
    @Query private var workoutLogs: [WorkoutLog]
    @Query private var notes: [Note]

    @State private var entryGoal: Goal?
    @State private var entryText = ""
    @State private var newNote = ""

    private static let stripDays = 14

    init(day: Date, selectedDay: Binding<Date>) {
        self.day = day
        _selectedDay = selectedDay
        let start = day.adding(days: -(Self.stripDays - 1))
        let end = day
        _checkIns = Query(filter: #Predicate<CheckIn> { $0.day >= start && $0.day <= end })
        _foodLogs = Query(filter: #Predicate<FoodLog> { $0.day >= start && $0.day <= end })
        _workoutLogs = Query(filter: #Predicate<WorkoutLog> { $0.day >= start && $0.day <= end })
        _notes = Query(filter: #Predicate<Note> { $0.day == end }, sort: \Note.createdAt, order: .reverse)
    }

    var body: some View {
        let data = DayData(foodLogs: foodLogs, workoutLogs: workoutLogs, checkIns: checkIns, health: health.snapshot)
        let days = Days.ending(on: day, count: Self.stripDays)
        let ordered = Tracker.ordered(goals)
        let strips = Dictionary(uniqueKeysWithValues: ordered.map { ($0.persistentModelID, Tracker.history($0, days: days, data: data)) })
        let metCount = strips.values.filter { $0.last?.met == true }.count

        List {
            Section {
                DayStepper(day: $selectedDay)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(metCount)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(goals.count) goals met")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if health.isAvailable && !health.isConnected {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Apple Health to fill in steps, sleep and workouts automatically.")
                        Button("Connect Apple Health") {
                            Task { await health.connect() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            if goals.isEmpty {
                Section {
                    Text("You have no active goals. Add one in the Goals tab.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(GoalArea.allCases) { area in
                let areaGoals = ordered.filter { $0.area == area }
                if !areaGoals.isEmpty {
                    Section {
                        ForEach(areaGoals) { goal in
                            GoalRow(
                                goal: goal,
                                strip: strips[goal.persistentModelID] ?? [],
                                onToggle: { toggle(goal, data: data) },
                                onEnter: { beginEntry(goal, data: data) }
                            )
                        }
                    } header: {
                        Label(area.label, systemImage: area.symbol)
                            .foregroundStyle(area.color)
                    }
                }
            }

            foodSection(data.nutrition[day])
            trainingSection(data.training[day])
            notesSection
        }
        .refreshable { await health.refresh() }
        .alert(entryGoal?.title ?? "", isPresented: Binding(
            get: { entryGoal != nil },
            set: { if !$0 { entryGoal = nil } }
        )) {
            TextField(entryGoal?.unit ?? "Value", text: $entryText)
                .keyboardType(.decimalPad)
            Button("Save") { saveEntry() }
            Button("Clear entry", role: .destructive) { clearEntry() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let goal = entryGoal, !goal.targetText().isEmpty {
                Text("Target \(goal.targetText())")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func foodSection(_ nutrition: NutritionTotals?) -> some View {
        Section("Food") {
            if let n = nutrition {
                let targets = foodTargets
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        StatTile(label: "Calories", value: Fmt.num(n.kcal), unit: "kcal", target: targets[.kcal])
                        StatTile(label: "Protein", value: Fmt.num(n.protein, decimals: 0), unit: "g", target: targets[.protein])
                    }
                    GridRow {
                        StatTile(label: "Carbs", value: Fmt.num(n.carbs, decimals: 0), unit: "g", target: targets[.carbs])
                        StatTile(label: "Fat", value: Fmt.num(n.fat, decimals: 0), unit: "g", target: targets[.fat])
                    }
                }
                .padding(.vertical, 4)
                if n.missingMacros > 0 {
                    Text("\(n.missingMacros) item\(n.missingMacros == 1 ? "" : "s") logged without macros, so protein, carbs and fat are undercounted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing logged yet. Use the Food tab to log a meal.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var foodTargets: [GoalSource: String] {
        var out: [GoalSource: String] = [:]
        for goal in goals where goal.source.group == .food {
            out[goal.source] = goal.targetText()
        }
        return out
    }

    @ViewBuilder
    private func trainingSection(_ training: TrainingTotals?) -> some View {
        let fromHealth = health.workouts[day] ?? []
        Section("Training") {
            if training == nil && fromHealth.isEmpty {
                Text("No training logged.").foregroundStyle(.secondary)
            }
            if let training {
                ForEach(training.entries) { entry in
                    Text(entry.summary)
                }
            }
            ForEach(fromHealth) { workout in
                LabeledContent {
                    Text("\(Fmt.num(workout.minutes)) min")
                } label: {
                    Text(workout.name)
                    Text("Apple Health")
                }
            }
        }
    }

    private var notesSection: some View {
        Section {
            TextField("How did today go? What got in the way?", text: $newNote, axis: .vertical)
                .lineLimit(2...6)
            Button("Add note") {
                let body = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                context.insert(Note(day: day, body: body))
                newNote = ""
            }
            .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(notes) { note in
                Text(note.body)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(notes[index]) }
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("The coach reads your notes when it reviews your week.")
        }
    }

    // MARK: Actions

    private func toggle(_ goal: Goal, data: DayData) {
        if let existing = data.checkIn(for: goal, on: day) {
            existing.done.toggle()
        } else {
            let check = CheckIn(day: day, done: true)
            context.insert(check)
            check.goal = goal
        }
    }

    private func beginEntry(_ goal: Goal, data: DayData) {
        entryText = data.checkIn(for: goal, on: day)?.value.map { Fmt.plain($0) } ?? ""
        entryGoal = goal
    }

    private func saveEntry() {
        guard let goal = entryGoal else { return }
        defer { entryGoal = nil }
        guard let value = Fmt.parse(entryText) else { return }
        if let existing = checkIns.first(where: { $0.goal?.persistentModelID == goal.persistentModelID && $0.day == day }) {
            existing.value = value
        } else {
            let check = CheckIn(day: day, value: value)
            context.insert(check)
            check.goal = goal
        }
    }

    private func clearEntry() {
        guard let goal = entryGoal else { return }
        defer { entryGoal = nil }
        if let existing = checkIns.first(where: { $0.goal?.persistentModelID == goal.persistentModelID && $0.day == day }) {
            context.delete(existing)
        }
    }
}

private struct GoalRow: View {
    let goal: Goal
    let strip: [GoalStatus]
    let onToggle: () -> Void
    let onEnter: () -> Void

    private var status: GoalStatus { strip.last ?? .empty(.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if goal.kind == .check {
                    Button(action: onToggle) {
                        Tick(met: status.met == true, color: goal.area.color)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(status.met == true ? "Mark \(goal.title) not done" : "Mark \(goal.title) done")
                } else {
                    Tick(met: status.met == true, color: goal.area.color)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title)
                        .foregroundStyle(status.met == true ? Color.secondary : Color.primary)
                    if goal.kind == .amount {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }

            if goal.kind == .amount {
                ProgressBar(progress: status.progress, color: goal.area.color, over: status.over)
                    .padding(.leading, 36)
            }
            StreakStrip(statuses: strip, color: goal.area.color)
                .padding(.leading, 36)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let target = goal.targetText()
        let origin = goal.source == .manual ? "" : goal.source.origin
        return [target, origin].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private var trailing: some View {
        if goal.kind == .amount {
            if goal.source == .manual {
                Button(action: onEnter) {
                    Text(status.value.map { Fmt.num($0) } ?? "Enter")
                        .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Enter \(goal.title)")
            } else {
                Text(status.value.map { Fmt.num($0) } ?? "Not logged")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(status.over ? Theme.danger : (status.value == nil ? Color.secondary : Color.primary))
            }
        }
    }
}
