import Foundation
import SwiftUI
#if canImport(Combine)
import Combine
#endif

@MainActor
final class DynamicCatalogStore: ObservableObject {
    static let shared = DynamicCatalogStore()

    @Published private(set) var generatedSets: [GeneratedSet] = []
    @Published private(set) var dynamicCommons: [Skin] = []
    @Published private(set) var dynamicRares: [Skin] = []
    @Published private(set) var dynamicSpecials: [Skin] = []

    // Boost windows: setID -> boostUntilTotalBlocksViewed
    @Published private(set) var boostWindows: [UUID: Int] = [:]

    private init() { }

    func inject(set: GeneratedSet, boostUntil totalBlocks: Int) {
        generatedSets.append(set)
        for skin in set.skins {
            switch skin.rarity {
            case .common: dynamicCommons.append(skin)
            case .rare: dynamicRares.append(skin)
            case .special: dynamicSpecials.append(skin)
            }
        }
        boostWindows[set.id] = totalBlocks
        // Notify UI subtly (e.g., shimmer cue)
        NotificationCenter.default.post(name: .didInjectGeneratedSet, object: set.id)
    }

    func isBoostActive(nowTotal total: Int, for setID: UUID) -> Bool {
        guard let until = boostWindows[setID] else { return false }
        return total <= until
    }

    func expireBoostsIfNeeded(nowTotal total: Int) {
        boostWindows = boostWindows.filter { _, until in total <= until }
    }
}

extension Notification.Name {
    static let didInjectGeneratedSet = Notification.Name("didInjectGeneratedSet")
}
