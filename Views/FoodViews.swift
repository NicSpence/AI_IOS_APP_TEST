import SwiftUI
import SwiftData

struct FoodView: View {
    @State private var day = Date().startOfDay

    var body: some View {
        NavigationStack {
            FoodDayList(day: day, selectedDay: $day)
                .id(day)
                .navigationTitle("Food")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct FoodDayList: View {
    let day: Date
    @Binding var selectedDay: Date

    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health
    @Query private var logs: [FoodLog]
    @Query(filter: #Predicate<Goal> { $0.isActive == true }) private var goals: [Goal]
    @State private var showAdd = false

    init(day: Date, selectedDay: Binding<Date>) {
        self.day = day
        _selectedDay = selectedDay
        let target = day
        _logs = Query(filter: #Predicate<FoodLog> { $0.day == target }, sort: \FoodLog.createdAt)
    }

    var body: some View {
        let totals = DayData(foodLogs: logs, workoutLogs: [], checkIns: [], health: [:]).nutrition[day]
        List {
            Section { DayStepper(day: $selectedDay) }

            if let n = totals {
                Section("Day total") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            StatTile(label: "Calories", value: Fmt.num(n.kcal), unit: "kcal", target: target(.kcal))
                            StatTile(label: "Protein", value: Fmt.num(n.protein, decimals: 0), unit: "g", target: target(.protein))
                        }
                        GridRow {
                            StatTile(label: "Carbs", value: Fmt.num(n.carbs, decimals: 0), unit: "g", target: target(.carbs))
                            StatTile(label: "Fat", value: Fmt.num(n.fat, decimals: 0), unit: "g", target: target(.fat))
                        }
                    }
                    .padding(.vertical, 4)
                    if n.missingMacros > 0 {
                        NavigationLink {
                            FoodLibraryView(startWithMissingOnly: true)
                        } label: {
                            Text("Some foods have calories but no macros. Fill them in to make these totals accurate.")
                                .font(.footnote)
                        }
                    }
                }
            }

            ForEach(Meal.allCases) { meal in
                let items = logs.filter { $0.meal == meal }
                if !items.isEmpty {
                    Section(meal.label) {
                        ForEach(items) { log in
                            FoodLogRow(log: log)
                        }
                        .onDelete { offsets in delete(offsets.map { items[$0] }) }
                    }
                }
            }

            if logs.isEmpty {
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Log your first meal for this day", systemImage: "plus.circle")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    FoodLibraryView()
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("Food library")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Log food")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddFoodSheet(day: day)
        }
    }

    private func target(_ source: GoalSource) -> String? {
        goals.first { $0.source == source }?.targetText()
    }

    private func delete(_ items: [FoodLog]) {
        for log in items {
            let syncID = log.syncID
            Task { await health.deleteFood(syncID: syncID) }
            context.delete(log)
        }
    }
}

private struct FoodLogRow: View {
    let log: FoodLog

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text([log.food?.emoji, log.food?.name].compactMap { $0 }.joined(separator: " "))
                Spacer()
                Text("\(Fmt.num(log.kcal)) kcal").monospacedDigit()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = ["\(Fmt.num(log.grams)) g"]
        if let p = log.protein { parts.append("\(Fmt.num(p, decimals: 0)) g protein") }
        if let c = log.carbs { parts.append("\(Fmt.num(c, decimals: 0)) g carbs") }
        if let f = log.fat { parts.append("\(Fmt.num(f, decimals: 0)) g fat") }
        if log.protein == nil { parts.append("no macro data") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Logging

struct AddFoodSheet: View {
    let day: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(HealthStore.self) private var health

    @State private var search = ""
    @State private var selected: FoodItem?
    @State private var amountText = ""
    @State private var usePieces = false
    @State private var meal = Meal.current
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let food = selected {
                    amountForm(food)
                } else {
                    FoodSearchList(search: search) { food in
                        selected = food
                        usePieces = food.unitGrams != nil
                        amountText = ""
                        amountFocused = true
                    }
                    .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Chicken, rice, banana")
                }
            }
            .navigationTitle(selected?.name ?? "Log food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Log food") { log() }
                            .disabled(grams == nil)
                    }
                }
            }
        }
    }

    private var grams: Double? {
        guard let food = selected, let qty = Fmt.parse(amountText), qty > 0 else { return nil }
        if usePieces {
            guard let unit = food.unitGrams else { return nil }
            return qty * unit
        }
        return qty
    }

    private func amountForm(_ food: FoodItem) -> some View {
        Form {
            Section {
                LabeledContent("Per 100 g", value: "\(Fmt.num(food.kcal)) kcal")
                if food.macrosKnown {
                    LabeledContent("Protein, carbs, fat", value: "\(Fmt.num(food.protein)), \(Fmt.num(food.carbs)), \(Fmt.num(food.fat)) g")
                } else {
                    Text("This food has calories only, so it won't count toward protein, carbs or fat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Amount") {
                TextField(usePieces ? "Pieces" : "Grams", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                if let unit = food.unitGrams {
                    Picker("Unit", selection: $usePieces) {
                        Text("grams").tag(false)
                        Text("pieces (\(Fmt.num(unit)) g each)").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if let grams {
                    let kcal = food.kcal * grams / 100
                    let protein = food.protein.map { $0 * grams / 100 }
                    Text(protein.map { "\(Fmt.num(grams)) g, about \(Fmt.num(kcal)) kcal and \(Fmt.num($0, decimals: 0)) g protein" }
                         ?? "\(Fmt.num(grams)) g, about \(Fmt.num(kcal)) kcal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(Meal.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Button("Choose a different food") {
                    selected = nil
                }
            }
        }
    }

    private func log() {
        guard let food = selected, let grams else { return }
        let entry = FoodLog(day: day, meal: meal, grams: grams)
        context.insert(entry)
        entry.food = food
        Task { await health.saveFood(entry) }
        dismiss()
    }
}

/// Search results backed by a query that's rebuilt as the search text changes.
private struct FoodSearchList: View {
    @Query private var foods: [FoodItem]
    let term: String
    let onPick: (FoodItem) -> Void

    init(search: String, onPick: @escaping (FoodItem) -> Void) {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.term = term
        self.onPick = onPick
        var descriptor = term.isEmpty
            ? FetchDescriptor<FoodItem>()
            : FetchDescriptor<FoodItem>(predicate: #Predicate<FoodItem> { $0.name.localizedStandardContains(term) })
        descriptor.sortBy = [SortDescriptor(\FoodItem.sortRank), SortDescriptor(\FoodItem.name)]
        descriptor.fetchLimit = 60
        _foods = Query(descriptor)
    }

    var body: some View {
        List {
            ForEach(foods) { food in
                Button {
                    onPick(food)
                } label: {
                    FoodItemLabel(food: food)
                }
                .tint(Color.primary)
            }
            if !term.isEmpty {
                Section {
                    NavigationLink {
                        FoodEditor(food: nil, initialName: term, onSave: onPick)
                    } label: {
                        Label("Add “\(term)” to your food library", systemImage: "plus")
                    }
                }
            }
        }
    }
}

struct FoodItemLabel: View {
    let food: FoodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text([food.emoji, food.name].compactMap { $0 }.joined(separator: " "))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var parts = ["\(Fmt.num(food.kcal)) kcal per 100 g"]
        if let p = food.protein { parts.append("\(Fmt.num(p)) g protein") } else { parts.append("calories only") }
        if let unit = food.unitGrams { parts.append("1 piece ≈ \(Fmt.num(unit)) g") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Library

struct FoodLibraryView: View {
    let startWithMissingOnly: Bool

    init(startWithMissingOnly: Bool = false) {
        self.startWithMissingOnly = startWithMissingOnly
    }

    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var missingOnly = false
    @State private var importing = false
    @State private var message: String?
    @State private var didApplyStart = false

    var body: some View {
        FoodLibraryList(search: search, missingOnly: missingOnly)
            .searchable(text: $search, prompt: "Search foods")
            .navigationTitle("Food library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Missing macros only", isOn: $missingOnly)
                        Button {
                            Task { await importOpenFoodCalories() }
                        } label: {
                            Label("Import 5,000 foods (calories only)", systemImage: "square.and.arrow.down")
                        }
                        .disabled(importing)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Library options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        FoodEditor(food: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add food")
                }
            }
            .overlay(alignment: .bottom) {
                if importing {
                    ProgressView("Importing foods…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .alert("Food library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .onAppear {
                if !didApplyStart {
                    missingOnly = startWithMissingOnly
                    didApplyStart = true
                }
            }
    }

    private func importOpenFoodCalories() async {
        importing = true
        defer { importing = false }
        do {
            let added = try await Importers.importOpenFoodCalories(into: context)
            message = "Added \(added) foods. They have calories only; fill in macros for the ones you eat often."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

private struct FoodLibraryList: View {
    @Query private var foods: [FoodItem]

    init(search: String, missingOnly: Bool) {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate: Predicate<FoodItem>?
        switch (term.isEmpty, missingOnly) {
        case (true, false): predicate = nil
        case (true, true): predicate = #Predicate<FoodItem> { $0.sortRank == 1 }
        case (false, false): predicate = #Predicate<FoodItem> { $0.name.localizedStandardContains(term) }
        case (false, true): predicate = #Predicate<FoodItem> { $0.sortRank == 1 && $0.name.localizedStandardContains(term) }
        }
        var descriptor = FetchDescriptor<FoodItem>(predicate: predicate,
                                                   sortBy: [SortDescriptor(\FoodItem.sortRank), SortDescriptor(\FoodItem.name)])
        descriptor.fetchLimit = 300
        _foods = Query(descriptor)
    }

    var body: some View {
        List(foods) { food in
            NavigationLink {
                FoodEditor(food: food)
            } label: {
                FoodItemLabel(food: food)
            }
        }
        .overlay {
            if foods.isEmpty {
                ContentUnavailableView("No foods found", systemImage: "fork.knife",
                                       description: Text("Add it with the + button."))
            }
        }
    }
}

struct FoodEditor: View {
    let food: FoodItem?
    var initialName = ""
    var onSave: (FoodItem) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var fiber = ""
    @State private var unitGrams = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } footer: {
                if let source = food?.source, source != "custom" { Text("From \(source).") }
            }
            Section {
                numberField("Calories (kcal)", $kcal)
                numberField("Protein (g)", $protein)
                numberField("Carbs (g)", $carbs)
                numberField("Fat (g)", $fat)
                numberField("Fiber (g)", $fiber)
            } header: {
                Text("Per 100 g")
            }
            Section {
                numberField("Weight of one piece (g)", $unitGrams)
            } footer: {
                Text("Lets you log “2 eggs” instead of grams.")
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle(food == nil ? "New food" : "Edit food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save food") { save() }
            }
        }
        .onAppear(perform: load)
    }

    private func numberField(_ label: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let food else {
            name = initialName
            return
        }
        name = food.name
        kcal = Fmt.plain(food.kcal)
        protein = Fmt.plain(food.protein)
        carbs = Fmt.plain(food.carbs)
        fat = Fmt.plain(food.fat)
        fiber = Fmt.plain(food.fiber)
        unitGrams = Fmt.plain(food.unitGrams)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let kcalValue = Fmt.parse(kcal) else {
            error = "A food needs a name and calories per 100 g."
            return
        }
        let target: FoodItem
        if let food {
            target = food
        } else {
            let lower = trimmed.lowercased()
            let existing = (try? context.fetch(FetchDescriptor<FoodItem>(predicate: #Predicate<FoodItem> { $0.name.localizedStandardContains(trimmed) }))) ?? []
            if existing.contains(where: { $0.name.lowercased() == lower }) {
                error = "“\(trimmed)” is already in your library."
                return
            }
            target = FoodItem(name: trimmed, kcal: kcalValue)
            context.insert(target)
        }
        target.name = trimmed
        target.kcal = kcalValue
        target.protein = Fmt.parse(protein)
        target.carbs = Fmt.parse(carbs)
        target.fat = Fmt.parse(fat)
        target.fiber = Fmt.parse(fiber)
        target.unitGrams = Fmt.parse(unitGrams).flatMap { $0 > 0 ? $0 : nil }
        target.updateRank()
        try? context.save()
        onSave(target)
        dismiss()
    }
}
