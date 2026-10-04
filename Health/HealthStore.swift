import Foundation
import HealthKit
import Observation

/// Daily values read from Apple Health. Raw values match the Apple Health cases of `GoalSource`.
enum HealthMetric: String, CaseIterable {
    case steps, sleepHours, exerciseMinutes, workoutMinutes, waterLiters, mindfulMinutes, activeEnergy
}

struct HealthWorkout: Identifiable {
    let id: UUID
    let day: Date
    let name: String
    let minutes: Double
    let kcal: Double?
}

@MainActor
@Observable
final class HealthStore {
    private let store = HKHealthStore()
    private static let connectedKey = "tally.health.connected"
    private static let writeFoodKey = "tally.health.writeFood"
    /// Metadata key used to find this app's food samples again.
    static let syncKey = "TallyLogID"

    private(set) var snapshot: HealthSnapshot = [:]
    private(set) var workouts: [Date: [HealthWorkout]] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var lastError: String?

    var isConnected: Bool = UserDefaults.standard.bool(forKey: HealthStore.connectedKey) {
        didSet { UserDefaults.standard.set(isConnected, forKey: Self.connectedKey) }
    }

    var writesFood: Bool = UserDefaults.standard.object(forKey: HealthStore.writeFoodKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(writesFood, forKey: Self.writeFoodKey) }
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Authorization

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.dietaryWater),
            HKQuantityType(.activeEnergyBurned),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.mindfulSession),
            HKObjectType.workoutType(),
        ]
    }

    private static let foodTypes: [(HKQuantityTypeIdentifier, HKUnit)] = [
        (.dietaryEnergyConsumed, .kilocalorie()),
        (.dietaryProtein, .gram()),
        (.dietaryCarbohydrates, .gram()),
        (.dietaryFatTotal, .gram()),
        (.dietaryFiber, .gram()),
    ]

    private var shareTypes: Set<HKSampleType> {
        Set(Self.foodTypes.map { HKQuantityType($0.0) })
    }

    /// Shows the Health permission sheet. iOS never tells apps which read types were denied;
    /// denied types simply return no data.
    func connect() async {
        guard isAvailable else {
            lastError = "Apple Health isn't available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            isConnected = true
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Reading

    /// Reloads the last `days` days. Each metric is read independently so one failure doesn't hide the rest.
    func refresh(days: Int = 31) async {
        guard isAvailable, isConnected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let start = Date().startOfDay.adding(days: -(days - 1))
        let end = Date().startOfDay.adding(days: 1)
        var result: HealthSnapshot = [:]

        func merge(_ values: [Date: Double], into metric: HealthMetric) {
            for (day, value) in values { result[day, default: [:]][metric] = value }
        }

        if let v = try? await dailySums(.stepCount, unit: .count(), from: start, to: end) { merge(v, into: .steps) }
        if let v = try? await dailySums(.appleExerciseTime, unit: .minute(), from: start, to: end) { merge(v, into: .exerciseMinutes) }
        if let v = try? await dailySums(.dietaryWater, unit: .liter(), from: start, to: end) { merge(v, into: .waterLiters) }
        if let v = try? await dailySums(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end) { merge(v, into: .activeEnergy) }
        if let v = try? await sleepHours(from: start, to: end) { merge(v, into: .sleepHours) }
        if let v = try? await mindfulMinutes(from: start, to: end) { merge(v, into: .mindfulMinutes) }

        if let list = try? await loadWorkouts(from: start, to: end) {
            workouts = Dictionary(grouping: list, by: \.day)
            let minutesByDay = workouts.mapValues { list in list.reduce(0) { total, w in total + w.minutes } }
            merge(minutesByDay, into: .workoutMinutes)
        }

        snapshot = result
        lastRefresh = .now
    }

    private func dailySums(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async throws -> [Date: Double] {
        let type = HKQuantityType(id)
        let predicate = HKSamplePredicate.quantitySample(
            type: type,
            predicate: HKQuery.predicateForSamples(withStart: start, end: end)
        )
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate,
            options: .cumulativeSum,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await query.result(for: store)
        var out: [Date: Double] = [:]
        for stats in collection.statistics() {
            if let sum = stats.sumQuantity() {
                out[stats.startDate.startOfDay] = sum.doubleValue(for: unit)
            }
        }
        return out
    }

    private func categoryIntervals(_ id: HKCategoryTypeIdentifier, from start: Date, to end: Date,
                                   include: (Int) -> Bool) async throws -> [DateInterval] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(id),
                                         predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        let intervals = samples
            .filter { include($0.value) && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        return Self.mergeOverlaps(intervals)
    }

    /// iPhone and Apple Watch often record the same sleep; merging overlaps avoids counting it twice.
    private static func mergeOverlaps(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func overlapSeconds(_ intervals: [DateInterval], with window: DateInterval) -> Double {
        intervals.reduce(0) { total, interval in
            total + (interval.intersection(with: window)?.duration ?? 0)
        }
    }

    /// Sleep counts toward the day you wake up: the window runs from 6 pm the previous evening to 6 pm.
    private func sleepHours(from start: Date, to end: Date) async throws -> [Date: Double] {
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals = try await categoryIntervals(.sleepAnalysis, from: start.addingTimeInterval(-6 * 3600), to: end) {
            asleep.contains($0)
        }
        var out: [Date: Double] = [:]
        var day = start
        while day < end {
            let window = DateInterval(start: day.addingTimeInterval(-6 * 3600), end: day.addingTimeInterval(18 * 3600))
            let seconds = Self.overlapSeconds(intervals, with: window)
            if seconds > 0 { out[day] = seconds / 3600 }
            day = day.adding(days: 1)
        }
        return out
    }

    private func mindfulMinutes(from start: Date, to end: Date) async throws -> [Date: Double] {
        let intervals = try await categoryIntervals(.mindfulSession, from: start, to: end) { _ in true }
        var out: [Date: Double] = [:]
        var day = start
        while day < end {
            let seconds = Self.overlapSeconds(intervals, with: DateInterval(start: day, end: day.adding(days: 1)))
            if seconds > 0 { out[day] = seconds / 60 }
            day = day.adding(days: 1)
        }
        return out
    }

    private func loadWorkouts(from start: Date, to end: Date) async throws -> [HealthWorkout] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let results = try await descriptor.result(for: store)
        return results.map { workout in
            HealthWorkout(
                id: workout.uuid,
                day: workout.startDate.startOfDay,
                name: Self.name(for: workout.workoutActivityType),
                minutes: workout.duration / 60,
                kcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            )
        }
    }

    private static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .cycling: "Cycle"
        case .swimming: "Swim"
        case .rowing: "Row"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stairs"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .traditionalStrengthTraining: "Strength training"
        case .functionalStrengthTraining: "Functional strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .coreTraining: "Core training"
        case .flexibility: "Flexibility"
        case .crossTraining: "Cross training"
        case .mixedCardio: "Mixed cardio"
        case .soccer: "Football"
        case .tennis: "Tennis"
        case .basketball: "Basketball"
        default: "Workout"
        }
    }

    // MARK: Writing food

    /// Writes a food entry's nutrients to Apple Health, tagged so they can be removed later.
    func saveFood(_ log: FoodLog) async {
        guard isAvailable, isConnected, writesFood, let food = log.food else { return }
        let when = log.day.isToday ? Date() : log.day.addingTimeInterval(12 * 3600)
        let metadata: [String: Any] = [HKMetadataKeyFoodType: food.name, Self.syncKey: log.syncID.uuidString]
        let values: [HKQuantityTypeIdentifier: Double?] = [
            .dietaryEnergyConsumed: log.kcal,
            .dietaryProtein: log.protein,
            .dietaryCarbohydrates: log.carbs,
            .dietaryFatTotal: log.fat,
            .dietaryFiber: log.fiber,
        ]
        var samples: [HKQuantitySample] = []
        for (id, unit) in Self.foodTypes {
            guard let optional = values[id], let value = optional, value > 0 else { continue }
            samples.append(HKQuantitySample(type: HKQuantityType(id),
                                            quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: when, end: when, metadata: metadata))
        }
        guard !samples.isEmpty else { return }
        do {
            try await store.save(samples)
        } catch {
            lastError = "Couldn't save to Apple Health: \(error.localizedDescription)"
        }
    }

    func deleteFood(syncID: UUID) async {
        guard isAvailable, isConnected else { return }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.syncKey, allowedValues: [syncID.uuidString])
        for (id, _) in Self.foodTypes {
            _ = try? await store.deleteObjects(of: HKQuantityType(id), predicate: predicate)
        }
    }
}
