import Foundation
import SwiftData

/// Optional imports run from the libraries. Existing names are never overwritten,
/// so starter foods keep their macros.
@MainActor
enum Importers {
    static let wgerURL = URL(string: "https://wger.de/api/v2/exerciseinfo/?limit=100&offset=0")!
    static let openFoodCaloriesURL = URL(string: "https://raw.githubusercontent.com/chpalitom09-bot/Open-food-calories/main/data/food.json")!

    // MARK: wger

    private struct WgerPage: Decodable {
        let next: String?
        let results: [WgerExercise]
    }

    private struct WgerExercise: Decodable {
        let id: Int
        let uuid: String?
        let category: Named?
        let muscles: [Muscle]?
        let musclesSecondary: [Muscle]?
        let equipment: [Named]?
        let translations: [Translation]?
        let exercises: [Translation]?   // older API versions
    }

    private struct Named: Decodable { let name: String? }
    private struct Muscle: Decodable { let name: String?; let nameEn: String? }

    private struct Translation: Decodable {
        let name: String?
        let description: String?
        let language: Int?

        enum CodingKeys: String, CodingKey { case name, description, language }
        private struct LanguageObject: Decodable { let id: Int }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            // language is an id in current API versions and an object in some older ones.
            if let id = try? c.decodeIfPresent(Int.self, forKey: .language) {
                language = id
            } else {
                language = (try? c.decodeIfPresent(LanguageObject.self, forKey: .language))?.id
            }
        }
    }

    /// Imports the wger catalogue. `languageID` 2 is English. Returns the number added.
    static func importWger(into context: ModelContext, languageID: Int = 2,
                           progress: (Int) -> Void = { _ in }) async throws -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map { $0.name.lowercased() })
        var seen = existing
        var added = 0
        var next: URL? = wgerURL
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        while let url = next {
            let (data, response) = try await URLSession.shared.data(from: url)
            try check(response)
            let page = try decoder.decode(WgerPage.self, from: data)

            for item in page.results {
                let translations = item.translations ?? item.exercises ?? []
                guard let translation = translations.first(where: { $0.language == languageID }),
                      let rawName = translation.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawName.isEmpty, !seen.contains(rawName.lowercased()) else { continue }

                let muscleNames = ((item.muscles ?? []) + (item.musclesSecondary ?? []))
                    .compactMap { ($0.nameEn?.nilIfEmpty ?? $0.name)?.nilIfEmpty }
                let muscles = Array(Set(muscleNames)).sorted().joined(separator: ", ")
                let equipment = (item.equipment ?? []).compactMap(\.name).joined(separator: ", ")

                context.insert(Exercise(
                    name: rawName,
                    category: item.category?.name,
                    muscles: muscles.nilIfEmpty,
                    equipment: equipment.nilIfEmpty,
                    details: stripHTML(translation.description ?? "").nilIfEmpty.map { String($0.prefix(1500)) },
                    source: "wger",
                    externalID: item.uuid ?? String(item.id)
                ))
                seen.insert(rawName.lowercased())
                added += 1
            }
            progress(added)
            try context.save()
            next = page.next.flatMap(URL.init(string:))
        }
        return added
    }

    // MARK: Open-food-calories (calories per 100 g only)

    private struct OFCItem: Decodable {
        let name: String?
        let englishName: String?
        let kcalPer100g: Double?
        let emoji: String?
        let weightPerUnit: Double?

        enum CodingKeys: String, CodingKey {
            case name, emoji
            case englishName = "english_name"
            case kcalPer100g = "kcal_per_100g"
            case weightPerUnit = "weight_per_unit"
        }
    }

    static func importOpenFoodCalories(into context: ModelContext) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(from: openFoodCaloriesURL)
        try check(response)
        let items = try JSONDecoder().decode([OFCItem].self, from: data)

        var seen = Set(((try? context.fetch(FetchDescriptor<FoodItem>())) ?? []).map { $0.name.lowercased() })
        var added = 0
        for item in items {
            guard let name = (item.englishName ?? item.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, let kcal = item.kcalPer100g, !seen.contains(name.lowercased()) else { continue }
            let food = FoodItem(name: name, kcal: kcal, unitGrams: (item.weightPerUnit ?? 0) > 0 ? item.weightPerUnit : nil,
                                emoji: item.emoji, source: "open-food-calories")
            if let french = item.name, french != name { food.altName = french }
            context.insert(food)
            seen.insert(name.lowercased())
            added += 1
            if added % 500 == 0 { try context.save() }
        }
        try context.save()
        return added
    }

    // MARK: Helpers

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
