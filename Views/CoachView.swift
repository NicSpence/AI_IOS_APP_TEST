import SwiftUI
import SwiftData

struct CoachView: View {
    @Environment(\.modelContext) private var context
    @Environment(CoachService.self) private var coach
    @Environment(HealthStore.self) private var health
    @Query(sort: \CoachReport.createdAt, order: .reverse) private var reports: [CoachReport]
    @Query private var notes: [Note]

    @AppStorage("coach.aboutMe") private var aboutMe = ""
    @State private var days = 7
    @State private var newNote = ""
    @State private var confirmation: String?

    init() {
        var descriptor = FetchDescriptor<Note>(sortBy: [SortDescriptor(\Note.createdAt, order: .reverse)])
        descriptor.fetchLimit = 20
        _notes = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            List {
                runSection

                if let latest = reports.first {
                    reportSections(latest)
                } else {
                    Section {
                        Text("No reviews yet. Log a few days, add a note or two, then get feedback.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Age, what you're training for, injuries, budget goals, what you're studying, what kind of feedback helps you.",
                              text: $aboutMe, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("About you")
                } footer: {
                    Text("Sent with every review.")
                }

                notesSection

                if reports.count > 1 {
                    Section("Earlier reviews") {
                        ForEach(reports.dropFirst()) { report in
                            DisclosureGroup("\(report.startDay.shortDay) to \(report.endDay.shortDay)") {
                                Text(report.summary)
                                ForEach(report.orderedSuggestions) { suggestion in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(describe(suggestion))
                                        Spacer()
                                        Text(suggestion.status.rawValue.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Coach")
            .alert("Coach", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(confirmation ?? "")
            }
        }
    }

    // MARK: Sections

    private var runSection: some View {
        Section {
            if let reason = coach.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.danger)
            }
            Picker("Review the last", selection: $days) {
                Text("3 days").tag(3)
                Text("5 days").tag(5)
                Text("7 days").tag(7)
            }
            Button {
                Task {
                    await coach.run(days: days, aboutMe: aboutMe, health: health.snapshot, context: context)
                }
            } label: {
                if coach.status == .running {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reviewing your days…")
                    }
                } else {
                    Text("Get feedback")
                }
            }
            .disabled(coach.status == .running || coach.unavailableReason != nil)

            if case .failed(let message) = coach.status {
                Text(message)
                    .foregroundStyle(Theme.danger)
                    .onTapGesture { coach.clearError() }
            }
        } footer: {
            Text("Runs on this iPhone with Apple Intelligence. Your data doesn't leave the device.")
        }
    }

    @ViewBuilder
    private func reportSections(_ report: CoachReport) -> some View {
        Section {
            Text(report.summary)
            if !report.wins.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Going well").font(.subheadline.weight(.semibold))
                    ForEach(Array(report.wins.enumerated()), id: \.offset) { _, win in
                        Label(win, systemImage: "checkmark.circle")
                    }
                }
                .padding(.vertical, 2)
            }
            if !report.concerns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watch").font(.subheadline.weight(.semibold))
                    ForEach(Array(report.concerns.enumerated()), id: \.offset) { _, concern in
                        Label(concern, systemImage: "eye")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Latest review, \(report.startDay.shortDay) to \(report.endDay.shortDay)")
        }

        if !report.suggestions.isEmpty {
            Section("Suggestions") {
                ForEach(report.orderedSuggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: CoachSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(suggestion.area?.color ?? Color.secondary)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(describe(suggestion)).font(.body.weight(.semibold))
                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason).font(.subheadline).foregroundStyle(.secondary)
                }
                if suggestion.status == .pending {
                    HStack {
                        Button(suggestion.kind == .tip ? "Got it" : "Apply change") {
                            confirmation = coach.resolve(suggestion, accept: true, context: context)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") {
                            confirmation = coach.resolve(suggestion, accept: false, context: context)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text(suggestion.status == .accepted && suggestion.kind != .tip ? "Applied" : suggestion.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var notesSection: some View {
        Section {
            TextField("Anything the coach should know about today", text: $newNote, axis: .vertical)
                .lineLimit(2...6)
            Button("Add note") {
                let body = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                context.insert(Note(day: .now, body: body))
                newNote = ""
            }
            .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.day.shortDay).font(.caption).foregroundStyle(.secondary)
                    Text(note.body)
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(notes[index]) }
            }
        } header: {
            Text("Notes")
        }
    }

    private func describe(_ s: CoachSuggestion) -> String {
        switch s.kind {
        case .adjustTarget:
            guard let goal = s.goal else { return s.title }
            let from = s.status == .accepted ? s.previousTarget : goal.target
            let unit = s.unit ?? goal.unit
            return "Change \(goal.title) from \(Fmt.num(from)) to \(Fmt.num(s.target)) \(unit)".trimmingCharacters(in: .whitespaces)
        case .newGoal:
            let target = s.target.map { " (\(Fmt.num($0)) \(s.unit ?? ""))".replacingOccurrences(of: " )", with: ")") } ?? ""
            return "New \(s.area?.label.lowercased() ?? "") goal: \(s.title)\(target)"
        case .pauseGoal:
            return "Pause \(s.goal?.title ?? s.title)"
        case .tip:
            return s.title
        }
    }
}
