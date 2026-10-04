import Foundation
import FoundationModels

// Guided generation: the on-device model is constrained to fill these types exactly,
// so there's no JSON to parse. Marked nonisolated so they work when the project's
// default actor isolation is MainActor.

@Generable
nonisolated struct CoachReply {
    @Guide(description: "Two or three sentences on how the period went, citing real numbers from the log.")
    var summary: String

    @Guide(description: "Specific things that went well, each one short.", .maximumCount(3))
    var wins: [String]

    @Guide(description: "Specific things to watch, each one short.", .maximumCount(3))
    var concerns: [String]

    @Guide(description: "Small, concrete changes. Prefer adjusting an existing goal.", .maximumCount(4))
    var suggestions: [CoachIdea]
}

@Generable
nonisolated struct CoachIdea {
    @Guide(description: "adjustTarget changes an existing amount goal, newGoal adds a goal, pauseGoal pauses one, tip is advice with no goal change.")
    var kind: IdeaKind

    @Guide(description: "The number of an existing goal, e.g. 3 for G3. Required for adjustTarget and pauseGoal.")
    var goalNumber: Int?

    @Guide(description: "Short title, e.g. 'Protein 130 g' or 'Lights out by 23:00'.")
    var title: String

    @Guide(description: "Area for a newGoal.")
    var area: IdeaArea?

    @Guide(description: "The new target number for adjustTarget or newGoal.")
    var target: Double?

    @Guide(description: "Unit for the target, e.g. g, min, pages.")
    var unit: String?

    @Guide(description: "One sentence on why, based on the data.")
    var reason: String
}

@Generable
nonisolated enum IdeaKind {
    case adjustTarget, newGoal, pauseGoal, tip
}

@Generable
nonisolated enum IdeaArea {
    case fitness, health, financial, cognitive
}
