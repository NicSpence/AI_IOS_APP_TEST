import Foundation
import FoundationModels
import Observation
import SwiftData

/// The feedback loop:
/// 1. Summarise the last few days (goals, hit rates, food, training, Health, notes) as compact text.
/// 2. Include "About you" and what happened to earlier suggestions (accepted / dismissed / ignored).
/// 3. Ask the on-device model for a `CoachReply` via guided generation.
/// 4. Store it. Accepting a suggestion edits your goals; dismissing records a no.
/// 5. The next review sees those outcomes.
@MainActor
@Observable
final class CoachService {
    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// The on-device model has a small shared context (about 4K tokens for instructions,
    /// schema, prompt and answer together), so the data part is kept well under that.
    private let promptCharacterBudget = 6_500

    // MARK: Availability

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence, which the coach needs."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use the coach."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready on this iPhone. Try again in a little while."
        case .unavailable:
            return "The on-device model isn't available right now."
        @unknown default:
            return "The on-device model isn't available right now."
        }
    }

    // MARK: Running

    func run(days requestedDays: Int, aboutMe: String, health: HealthSnapshot, context: ModelContext) async {
        guard unavailableReason == nil else {
            status = .failed(unavailableReason ?? "The coach isn't available.")
            return
        }
        status = .running

        let goals = Tracker.ordered(fetchActiveGoals(context))
        let previous = fetchReports(context, limit: 2)
        var dayCount = max(3, min(requestedDays, 7))
        var noteLimit = 240

        while true {
            let input = CoachInput(goals: goals, days: Days.ending(on: .now, count: dayCount),
                                   context: context, health: health, previous: previous, aboutMe: aboutMe)
            var prompt = input.prompt(noteLimit: noteLimit)
            if prompt.count > promptCharacterBudget && noteLimit > 80 {
                noteLimit = 80
                prompt = input.prompt(noteLimit: noteLimit)
            }
            if prompt.count > promptCharacterBudget && dayCount > 3 {
                dayCount -= 2
                continue
            }

            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(
                    to: prompt,
                    generating: CoachReply.self,
                    options: GenerationOptions(temperature: 0.4)
                )
                save(response.content, goals: goals, days: input.days, context: context)
                status = .idle
                return
            } catch {
                let failure = Self.classify(error)
                if failure == .contextOverflow && dayCount > 3 {
                    dayCount -= 2
                    noteLimit = 80
                    continue
                }
                status = .failed(failure.message)
                return
            }
        }
    }

    func clearError() {
        if case .failed = status { status = .idle }
    }

    private enum Failure: Equatable {
        case contextOverflow, guardrail, refusal, rateLimited, notReady, unsupportedLanguage, timeout
        case other(String)

        var message: String {
            switch self {
            case .contextOverflow:
                return "There was too much to review at once. Try a shorter period or shorter notes."
            case .guardrail:
                return "Apple's safety filter stopped this review. Try again, or reword anything sensitive in your notes."
            case .refusal:
                return "The model declined this review. Try again, or reword anything sensitive in your notes."
            case .rateLimited:
                return "The model is busy right now. Wait a minute and try again."
            case .notReady:
                return "Apple Intelligence is still getting ready on this iPhone. Try again in a little while."
            case .unsupportedLanguage:
                return "The on-device model doesn't support your current language or region setting."
            case .timeout:
                return "The review took too long. Try a shorter period."
            case .other(let text):
                return "The model couldn't finish the review: \(text)"
            }
        }
    }

    /// iOS 27 replaced LanguageModelSession.GenerationError with separate error types.
    private static func classify(_ error: Error) -> Failure {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextOverflow
            case .guardrailViolation: return .guardrail
            case .refusal: return .refusal
            case .rateLimited: return .rateLimited
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .timeout: return .timeout
            default: return .other(error.localizedDescription)
            }
        }
        if error is SystemLanguageModel.Error { return .notReady }
        return .other(error.localizedDescription)
    }

    private static let instructions = """
    You are a practical personal coach reviewing someone's daily habit tracker. \
    Their goals cover fitness, health, financial and cognitive areas and are labelled G1, G2 and so on.

    Rules:
    - Base every statement on the data given and quote real numbers. Never invent data.
    - Be brief, specific and honest. Kind, not cheerleading.
    - Notes are the person's own words. Use them to understand why things happened.
    - Suggest at most four small, concrete changes. Prefer adjusting an existing goal over adding one.
    - A goal missed most days may need a smaller target. A goal met every day may be ready to grow.
    - "Not logged" means no entry, not failure. If logging is the problem, say so.
    - Never repeat a suggestion the person dismissed. Check whether accepted changes helped.
    - Give general wellbeing guidance only, not medical advice.
    """

    // MARK: Saving and applying

    private func save(_ reply: CoachReply, goals: [Goal], days: [Date], context: ModelContext) {
        // Anything left untouched since the last review counts as ignored. The next prompt shows that.
        let pendingRaw = SuggestionStatus.pending.rawValue
        let pending = (try? context.fetch(FetchDescriptor<CoachSuggestion>(
            predicate: #Predicate<CoachSuggestion> { $0.statusRaw == pendingRaw }
        ))) ?? []
        for suggestion in pending { suggestion.status = .ignored }

        let report = CoachReport(startDay: days.first ?? .now, endDay: days.last ?? .now,
                                 summary: reply.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                 wins: reply.wins, concerns: reply.concerns)
        context.insert(report)

        var order = 0
        for idea in reply.suggestions.prefix(4) {
            guard let cleaned = Self.clean(idea, goals: goals) else { continue }
            let suggestion = CoachSuggestion(kind: cleaned.kind, title: cleaned.title, area: cleaned.area,
                                             target: cleaned.target, unit: cleaned.unit,
                                             reason: cleaned.reason, order: order)
            context.insert(suggestion)
            suggestion.report = report
            suggestion.goal = cleaned.goal
            order += 1
        }
        try? context.save()
    }

    private struct CleanIdea {
        var kind: SuggestionKind
        var goal: Goal?
        var title: String
        var area: GoalArea?
        var target: Double?
        var unit: String?
        var reason: String
    }

    /// Anything the app can't safely apply is downgraded to a tip, so a small model can't corrupt goals.
    private static func clean(_ idea: CoachIdea, goals: [Goal]) -> CleanIdea? {
        let goal: Goal? = idea.goalNumber.flatMap { n in n >= 1 && n <= goals.count ? goals[n - 1] : nil }
        var kind: SuggestionKind = switch idea.kind {
        case .adjustTarget: .adjustTarget
        case .newGoal: .newGoal
        case .pauseGoal: .pauseGoal
        case .tip: .tip
        }
        let area: GoalArea? = idea.area.map(goalArea)
        var title = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = idea.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = idea.unit?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        if (kind == .adjustTarget || kind == .pauseGoal) && goal == nil { kind = .tip }
        if kind == .adjustTarget, let goal {
            if goal.kind != .amount || (idea.target ?? 0) <= 0 || idea.target == goal.target { kind = .tip }
        }
        if kind == .newGoal && (area == nil || title.isEmpty) { kind = .tip }
        if title.isEmpty { title = goal?.title ?? String(reason.prefix(80)) }
        guard !title.isEmpty else { return nil }

        let changesGoal = kind == .adjustTarget || kind == .newGoal
        return CleanIdea(
            kind: kind,
            goal: kind == .newGoal ? nil : goal,
            title: String(title.prefix(120)),
            area: goal?.area ?? area,
            target: changesGoal ? idea.target : nil,
            unit: changesGoal ? (unit ?? goal?.unit) : nil,
            reason: String(reason.prefix(400))
        )
    }

    private static func goalArea(_ area: IdeaArea) -> GoalArea {
        switch area {
        case .fitness: return .fitness
        case .health: return .health
        case .financial: return .financial
        case .cognitive: return .cognitive
        }
    }

    /// Returns a short confirmation to show the user.
    @discardableResult
    func resolve(_ suggestion: CoachSuggestion, accept: Bool, context: ModelContext) -> String {
        guard suggestion.status == .pending else { return "That suggestion was already handled." }
        suggestion.resolvedAt = .now

        guard accept else {
            suggestion.status = .dismissed
            try? context.save()
            return "Dismissed. The coach will see that next time."
        }

        let message: String
        switch suggestion.kind {
        case .adjustTarget:
            guard let goal = suggestion.goal, let target = suggestion.target else {
                suggestion.status = .dismissed
                return "That goal no longer exists."
            }
            suggestion.previousTarget = goal.target
            goal.target = target
            message = "Updated \(goal.title) to \(goal.targetText())."
        case .pauseGoal:
            guard let goal = suggestion.goal else {
                suggestion.status = .dismissed
                return "That goal no longer exists."
            }
            goal.isActive = false
            message = "Paused \(goal.title)."
        case .newGoal:
            let maxOrder = (try? context.fetch(FetchDescriptor<Goal>()))?.map(\.sortOrder).max() ?? 0
            let goal = Goal(title: suggestion.title, area: suggestion.area ?? .health,
                            kind: suggestion.target == nil ? .check : .amount,
                            target: suggestion.target, unit: suggestion.unit ?? "",
                            sortOrder: maxOrder + 1)
            context.insert(goal)
            message = "Added \(goal.title) to your goals."
        case .tip:
            message = "Noted."
        }
        suggestion.status = .accepted
        try? context.save()
        return message
    }

    // MARK: Fetching

    private func fetchActiveGoals(_ context: ModelContext) -> [Goal] {
        (try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate<Goal> { $0.isActive == true }))) ?? []
    }

    private func fetchReports(_ context: ModelContext, limit: Int) -> [CoachReport] {
        var descriptor = FetchDescriptor<CoachReport>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}

/// Builds the compact text the model reads.
@MainActor
struct CoachInput {
    let goals: [Goal]
    let days: [Date]
    let data: DayData
    let notes: [Date: [String]]
    let previous: [CoachReport]
    let aboutMe: String

    init(goals: [Goal], days: [Date], context: ModelContext, health: HealthSnapshot,
         previous: [CoachReport], aboutMe: String) {
        self.goals = goals
        self.days = days
        self.previous = previous
        self.aboutMe = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)

        let start = days.first ?? .now
        let end = days.last ?? .now
        let food = (try? context.fetch(FetchDescriptor<FoodLog>(predicate: #Predicate<FoodLog> { $0.day >= start && $0.day <= end }))) ?? []
        let training = (try? context.fetch(FetchDescriptor<WorkoutLog>(predicate: #Predicate<WorkoutLog> { $0.day >= start && $0.day <= end }))) ?? []
        let checks = (try? context.fetch(FetchDescriptor<CheckIn>(predicate: #Predicate<CheckIn> { $0.day >= start && $0.day <= end }))) ?? []
        let noteRows = (try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.day >= start && $0.day <= end },
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []

        data = DayData(foodLogs: food, workoutLogs: training, checkIns: checks, health: health)
        notes = Dictionary(grouping: noteRows, by: { $0.day.startOfDay }).mapValues { rows in
            rows.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func prompt(noteLimit: Int) -> String {
        var lines: [String] = []
        let first = days.first ?? .now, last = days.last ?? .now
        lines.append("Today is \(Date.now.formatted(.dateTime.weekday(.wide))) \(Date.now.isoDay). Review \(days.count) days, \(first.isoDay) to \(last.isoDay).")

        if !aboutMe.isEmpty {
            lines.append("")
            lines.append("ABOUT ME: \(aboutMe.prefix(600))")
        }

        lines.append("")
        lines.append("GOALS:")
        if goals.isEmpty { lines.append("(none)") }
        for (i, goal) in goals.enumerated() {
            let rate = Tracker.hitRate(goal, days: days, data: data)
            let target = goal.kind == .check ? "yes/no" : goal.targetText(words: true)
            lines.append("G\(i + 1) \(goal.area.rawValue): \(goal.title), \(target), \(goal.source.origin), met \(rate.met)/\(rate.total) days (\(rate.logged) logged)")
        }

        lines.append("")
        lines.append("DAYS:")
        for day in days {
            lines.append(dayLine(day, noteLimit: noteLimit))
        }

        if !previous.isEmpty {
            lines.append("")
            lines.append("YOUR EARLIER FEEDBACK AND WHAT THEY DID WITH IT:")
            for report in previous {
                lines.append("* \(report.createdAt.isoDay): \(report.summary.prefix(300))")
                for s in report.orderedSuggestions {
                    var change = ""
                    if s.kind == .adjustTarget, let target = s.target {
                        change = " (\(Fmt.num(s.previousTarget)) -> \(Fmt.num(target)))"
                    }
                    lines.append("  - [\(s.status.rawValue)] \(s.kind.rawValue): \(s.title)\(change)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func dayLine(_ day: Date, noteLimit: Int) -> String {
        let statuses = goals.map { ($0, Tracker.evaluate($0, on: day, data: data)) }
        let nutrition = data.nutrition[day]
        let training = data.training[day]
        let health = data.health[day] ?? [:]
        let dayNotes = notes[day] ?? []

        let label = "- \(day.formatted(.dateTime.weekday(.abbreviated))) \(day.isoDay):"
        if nutrition == nil && training == nil && health.isEmpty && dayNotes.isEmpty && statuses.allSatisfy({ $0.1.met == nil }) {
            return "\(label) nothing logged"
        }

        var parts: [String] = []
        if !goals.isEmpty {
            let met = statuses.filter { $0.1.met == true }.count
            parts.append("met \(met)/\(goals.count)")
            let missed = statuses.filter { $0.1.met == false }.map { goal, status in
                goal.kind == .check ? "\(goal.title) not done"
                    : "\(goal.title) \(Fmt.num(status.value))/\(Fmt.num(goal.target))\(goal.unit.isEmpty ? "" : " \(goal.unit)")"
            }
            if !missed.isEmpty { parts.append("missed: " + missed.joined(separator: ", ")) }
            let unlogged = statuses.filter { $0.1.met == nil }.map { $0.0.title }
            if !unlogged.isEmpty { parts.append("not logged: " + unlogged.joined(separator: ", ")) }
        }
        if let n = nutrition {
            var food = "food \(Fmt.num(n.kcal)) kcal, protein \(Fmt.num(n.protein, decimals: 0)) g, carbs \(Fmt.num(n.carbs, decimals: 0)) g, fat \(Fmt.num(n.fat, decimals: 0)) g"
            if n.missingMacros > 0 { food += " (\(n.missingMacros) items without macros)" }
            parts.append(food)
        }
        if let t = training {
            parts.append("trained: " + t.entries.map(\.summary).joined(separator: "; "))
        }
        var healthBits: [String] = []
        if let v = health[.steps] { healthBits.append("\(Fmt.num(v)) steps") }
        if let v = health[.sleepHours] { healthBits.append("slept \(Fmt.num(v)) h") }
        if let v = health[.workoutMinutes] { healthBits.append("workouts \(Fmt.num(v)) min") }
        if !healthBits.isEmpty { parts.append("health: " + healthBits.joined(separator: ", ")) }
        if !dayNotes.isEmpty {
            let text = dayNotes.joined(separator: " / ")
            let clipped = text.count > noteLimit ? String(text.prefix(noteLimit)) + "…" : text
            parts.append("note: \"\(clipped)\"")
        }
        return "\(label) " + parts.joined(separator: ". ")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
