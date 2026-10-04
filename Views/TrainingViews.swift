import SwiftUI
import SwiftData

struct TrainingView: View {
    @State private var day = Date().startOfDay

    var body: some View {
        NavigationStack {
            TrainingDayList(day: day, selectedDay: $day)
                .id(day)
                .navigationTitle("Training")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TrainingDayList: View {
    let day: Date
    @Binding var selectedDay: Date

    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health
    @Query private var logs: [WorkoutLog]
    @State private var showAdd = false

    init(day: Date, selectedDay: Binding<Date>) {
        self.day = day
        _selectedDay = selectedDay
        let target = day
        _logs = Query(filter: #Predicate<WorkoutLog> { $0.day == target }, sort: \WorkoutLog.createdAt)
    }

    var body: some View {
        let fromHealth = health.workouts[day] ?? []
        List {
            Section { DayStepper(day: $selectedDay) }

            Section {
                if logs.isEmpty {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Log an exercise", systemImage: "plus.circle")
                    }
                }
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.summary)
                        if !log.notes.isEmpty {
                            Text(log.notes).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(logs[index]) }
                }
            } header: {
                Text("Logged in Tally")
            } footer: {
                if !logs.isEmpty {
                    let minutes = logs.compactMap(\.minutes).reduce(0, +)
                    let sets = logs.compactMap(\.sets).reduce(0, +)
                    Text("\(sets) sets, \(Fmt.num(minutes)) minutes")
                }
            }

            if !fromHealth.isEmpty {
                Section("From Apple Health") {
                    ForEach(fromHealth) { workout in
                        LabeledContent(workout.name) {
                            Text(workout.kcal.map { "\(Fmt.num(workout.minutes)) min, \(Fmt.num($0)) kcal" }
                                 ?? "\(Fmt.num(workout.minutes)) min")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ExerciseLibraryView()
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("Exercise library")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Log exercise")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddWorkoutSheet(day: day)
        }
    }
}

// MARK: Logging

private struct AddWorkoutSheet: View {
    let day: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var search = ""
    @State private var selected: Exercise?
    @State private var sets = ""
    @State private var reps = ""
    @State private var weight = ""
    @State private var minutes = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Group {
                if let exercise = selected {
                    entryForm(exercise)
                } else {
                    ExerciseSearchList(search: search, onPick: pick, onCreate: create)
                        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Back squat, running, yoga")
                }
            }
            .navigationTitle(selected?.name ?? "Log exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Log exercise") { save() }
                            .disabled(!hasValues)
                    }
                }
            }
        }
    }

    private func lastLog(of exercise: Exercise) -> WorkoutLog? {
        exercise.logs.filter { $0.day <= day }.max { $0.createdAt < $1.createdAt }
    }

    private var hasValues: Bool {
        [sets, reps, weight, minutes].contains { Fmt.parse($0) != nil }
    }

    private func entryForm(_ exercise: Exercise) -> some View {
        Form {
            if let last = lastLog(of: exercise) {
                Section {
                    Text("Last time (\(last.day.shortDay)): \(last.summary)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                field("Sets", $sets, keyboard: .numberPad)
                field("Reps", $reps, keyboard: .numberPad)
                field("Weight (kg)", $weight, keyboard: .decimalPad)
                field("Minutes", $minutes, keyboard: .decimalPad)
            }
            Section {
                TextField("Notes, e.g. RPE 8, felt strong", text: $notes, axis: .vertical)
            }
            Section {
                Button("Choose a different exercise") { selected = nil }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        LabeledContent(label) {
            TextField("—", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
        }
    }

    private func pick(_ exercise: Exercise) {
        selected = exercise
        // Pre-fill from the last session so progressive overload is one tap away.
        if let last = lastLog(of: exercise) {
            sets = last.sets.map(String.init) ?? ""
            reps = last.reps.map(String.init) ?? ""
            weight = Fmt.plain(last.weightKg)
            minutes = Fmt.plain(last.minutes)
        } else {
            sets = ""; reps = ""; weight = ""; minutes = ""
        }
    }

    private func create(_ name: String) {
        let exercise = Exercise(name: name, category: "Other")
        context.insert(exercise)
        pick(exercise)
    }

    private func save() {
        guard let exercise = selected else { return }
        let log = WorkoutLog(day: day,
                             sets: Fmt.parse(sets).map { Int($0) },
                             reps: Fmt.parse(reps).map { Int($0) },
                             weightKg: Fmt.parse(weight),
                             minutes: Fmt.parse(minutes),
                             notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(log)
        log.exercise = exercise
        dismiss()
    }
}

private struct ExerciseSearchList: View {
    @Query private var exercises: [Exercise]
    let term: String
    let onPick: (Exercise) -> Void
    let onCreate: (String) -> Void

    init(search: String, onPick: @escaping (Exercise) -> Void, onCreate: @escaping (String) -> Void) {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.term = term
        self.onPick = onPick
        self.onCreate = onCreate
        var descriptor = term.isEmpty
            ? FetchDescriptor<Exercise>()
            : FetchDescriptor<Exercise>(predicate: #Predicate<Exercise> { $0.name.localizedStandardContains(term) })
        descriptor.sortBy = [SortDescriptor(\Exercise.name)]
        descriptor.fetchLimit = 60
        _exercises = Query(descriptor)
    }

    var body: some View {
        List {
            ForEach(exercises) { exercise in
                Button {
                    onPick(exercise)
                } label: {
                    ExerciseLabel(exercise: exercise)
                }
                .tint(Color.primary)
            }
            if !term.isEmpty && !exercises.contains(where: { $0.name.caseInsensitiveCompare(term) == .orderedSame }) {
                Section {
                    Button {
                        onCreate(term)
                    } label: {
                        Label("Add “\(term)” as a new exercise", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct ExerciseLabel: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name)
            let caption = [exercise.category, exercise.muscles].compactMap { $0 }.joined(separator: ", ")
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: Library

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var all: [Exercise]
    @State private var search = ""
    @State private var category = ""
    @State private var importing = false
    @State private var imported = 0
    @State private var message: String?
    @State private var showNew = false

    var body: some View {
        let categories = Array(Set(all.compactMap(\.category))).sorted()
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = all.filter { exercise in
            (category.isEmpty || exercise.category == category) &&
            (term.isEmpty || exercise.name.localizedStandardContains(term) || (exercise.muscles ?? "").localizedStandardContains(term))
        }

        List {
            Section {
                ForEach(shown.prefix(300)) { exercise in
                    NavigationLink {
                        ExerciseDetailView(exercise: exercise)
                    } label: {
                        ExerciseLabel(exercise: exercise)
                    }
                }
            } footer: {
                Text("\(all.count) exercises. Import the full wger catalogue from the menu.")
            }
        }
        .searchable(text: $search, prompt: "Search by name or muscle")
        .navigationTitle("Exercises")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag("")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        Task { await importWger() }
                    } label: {
                        Label("Import from wger", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importing)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter and import")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add exercise")
            }
        }
        .overlay(alignment: .bottom) {
            if importing {
                ProgressView("Importing from wger… \(imported) added")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
        .alert("Exercise library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showNew) {
            NewExerciseSheet(categories: categories)
        }
    }

    private func importWger() async {
        importing = true
        imported = 0
        defer { importing = false }
        do {
            let added = try await Importers.importWger(into: context) { count in imported = count }
            message = "Added \(added) exercises from wger."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

private struct ExerciseDetailView: View {
    let exercise: Exercise

    var body: some View {
        let history = exercise.logs.sorted { $0.createdAt > $1.createdAt }.prefix(15)
        List {
            Section {
                if let category = exercise.category { LabeledContent("Category", value: category) }
                if let muscles = exercise.muscles { LabeledContent("Muscles", value: muscles) }
                if let equipment = exercise.equipment { LabeledContent("Equipment", value: equipment) }
            }
            if let details = exercise.details, !details.isEmpty {
                Section("How to") { Text(details) }
            }
            Section("Recent sessions") {
                if history.isEmpty {
                    Text("Not logged yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(history)) { log in
                    LabeledContent(log.day.shortDay, value: log.summary.replacingOccurrences(of: exercise.name + " ", with: ""))
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NewExerciseSheet: View {
    let categories: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var category = ""
    @State private var muscles = ""
    @State private var equipment = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Category, e.g. Legs", text: $category)
                TextField("Muscles, e.g. Quads, Glutes", text: $muscles)
                TextField("Equipment, e.g. Barbell", text: $equipment)
            }
            .navigationTitle("New exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add exercise") {
                        context.insert(Exercise(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Other",
                            muscles: muscles.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                            equipment: equipment.trimmingCharacters(in: .whitespaces).nilIfEmpty
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
