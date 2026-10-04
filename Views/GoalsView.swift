import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health
    @Query(sort: \Goal.sortOrder) private var goals: [Goal]
    @Query private var checkIns: [CheckIn]
    @Query private var foodLogs: [FoodLog]
    @Query private var workoutLogs: [WorkoutLog]

    @State private var editing: Goal?
    @State private var creating = false

    init() {
        let start = Date().startOfDay.adding(days: -29)
        _checkIns = Query(filter: #Predicate<CheckIn> { $0.day >= start })
        _foodLogs = Query(filter: #Predicate<FoodLog> { $0.day >= start })
        _workoutLogs = Query(filter: #Predicate<WorkoutLog> { $0.day >= start })
    }

    var body: some View {
        let data = DayData(foodLogs: foodLogs, workoutLogs: workoutLogs, checkIns: checkIns, health: health.snapshot)
        let days = Days.ending(on: .now, count: 30)
        let active = Tracker.ordered(goals.filter(\.isActive))
        let paused = goals.filter { !$0.isActive }

        NavigationStack {
            List {
                Section {
                    ForEach(active) { goal in
                        row(goal, rate: Tracker.hitRate(goal, days: days, data: data))
                    }
                    .onMove { from, to in move(active, from: from, to: to) }
                } header: {
                    Text("Active")
                } footer: {
                    Text("Days met in the last 30. Drag to reorder within an area.")
                }

                if !paused.isEmpty {
                    Section("Paused") {
                        ForEach(paused) { goal in
                            row(goal, rate: nil)
                        }
                    }
                }
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add goal")
                }
            }
            .sheet(item: $editing) { goal in GoalEditor(goal: goal) }
            .sheet(isPresented: $creating) { GoalEditor(goal: nil) }
        }
    }

    private func row(_ goal: Goal, rate: (met: Int, logged: Int, total: Int)?) -> some View {
        Button {
            editing = goal
        } label: {
            HStack(spacing: 12) {
                AreaDot(area: goal.area)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title).foregroundStyle(Color.primary)
                    Text(caption(goal)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let rate {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(rate.met)").font(.title3.weight(.semibold)).monospacedDigit()
                        Text("/\(rate.total)").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .accessibilityLabel("Met \(rate.met) of \(rate.total) days")
                }
            }
        }
    }

    private func caption(_ goal: Goal) -> String {
        var parts = [goal.area.label]
        if goal.kind == .amount { parts.append(goal.targetText()) } else { parts.append("yes / no") }
        if goal.source != .manual { parts.append(goal.source.origin) }
        return parts.joined(separator: ", ")
    }

    private func move(_ list: [Goal], from: IndexSet, to: Int) {
        var reordered = list
        reordered.move(fromOffsets: from, toOffset: to)
        for (index, goal) in reordered.enumerated() { goal.sortOrder = index }
    }
}

struct GoalEditor: View {
    let goal: Goal?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health

    @State private var title = ""
    @State private var area: GoalArea = .health
    @State private var kind: GoalKind = .check
    @State private var source: GoalSource = .manual
    @State private var targetText = ""
    @State private var unit = ""
    @State private var direction: Direction = .atLeast
    @State private var isActive = true
    @State private var confirmDelete = false
    @State private var loaded = false

    private var effectiveKind: GoalKind { source == .manual ? kind : .amount }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Goal, e.g. Read 20 pages", text: $title)
                    Picker("Area", selection: $area) {
                        ForEach(GoalArea.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                }

                Section {
                    Picker("Value comes from", selection: $source) {
                        ForEach(GoalSource.Group.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(GoalSource.allCases.filter { $0.group == group }) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                        }
                    }
                    if source == .manual {
                        Picker("Type", selection: $kind) {
                            ForEach(GoalKind.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if effectiveKind == .amount {
                        LabeledContent("Target") {
                            TextField("0", text: $targetText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Unit") {
                            TextField("pages", text: $unit)
                                .multilineTextAlignment(.trailing)
                        }
                        Picker("Counts as met", selection: $direction) {
                            ForEach(Direction.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    Text("Tracking")
                } footer: {
                    if source.group == .health && !health.isConnected {
                        Text("This needs Apple Health. Connect it from Settings on the Today tab.")
                    } else if source.group == .food {
                        Text("Filled in from your food log each day.")
                    } else if source.group == .training {
                        Text("Filled in from exercises you log in Tally.")
                    }
                }

                if goal != nil {
                    Section {
                        Toggle("Show on daily checklist", isOn: $isActive)
                        Button("Delete goal", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(goal == nil ? "Add goal" : "Save goal") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: source) { oldValue, newValue in
                // Swap in the new source's unit unless the user typed their own.
                if unit.isEmpty || unit == oldValue.defaultUnit {
                    unit = newValue.defaultUnit
                }
            }
            .confirmationDialog("Delete this goal and all its check-ins?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete goal", role: .destructive) {
                    if let goal { context.delete(goal) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let goal else { return }
        title = goal.title
        area = goal.area
        kind = goal.kind
        source = goal.source
        targetText = Fmt.plain(goal.target)
        unit = goal.unit
        direction = goal.direction
        isActive = goal.isActive
    }

    private func save() {
        let target = effectiveKind == .amount ? Fmt.parse(targetText) : nil
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUnit = effectiveKind == .amount ? unit.trimmingCharacters(in: .whitespaces) : ""

        if let goal {
            goal.title = cleanTitle
            goal.area = area
            goal.kind = effectiveKind
            goal.source = source
            goal.target = target
            goal.unit = cleanUnit
            goal.direction = direction
            goal.isActive = isActive
        } else {
            let maxOrder = (try? context.fetch(FetchDescriptor<Goal>()))?.map(\.sortOrder).max() ?? 0
            context.insert(Goal(title: cleanTitle, area: area, kind: effectiveKind, target: target, unit: cleanUnit,
                                direction: direction, source: source, sortOrder: maxOrder + 1))
        }
        dismiss()
    }
}
