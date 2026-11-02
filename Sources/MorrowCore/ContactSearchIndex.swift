import Foundation

/// Full contact-topic search is prepared and evaluated off the UI actor.
/// Documents are reusable across claim/status updates and bounded in memory.
public actor ContactSearchIndex {
    private struct Entry {
        let display: String
        let email: String
        let topics: [String]
        let document: String
        var cost: Int { document.utf8.count }
        func matches(_ profile: ContactProfile) -> Bool { display == profile.display && email == profile.email && topics == profile.topics }
    }
    private var entries: [String: Entry] = [:]
    private var retained = 0
    private let maximumBytes: Int
    public init(maximumBytes: Int = 32 * 1024 * 1024) { self.maximumBytes = max(0, maximumBytes) }

    public func matchingIDs(in profiles: [ContactProfile], query: String) throws -> Set<String> {
        try Task.checkCancellation()
        let current = Set(profiles.map(\.id))
        for id in Set(entries.keys).subtracting(current) { if let entry = entries.removeValue(forKey: id) { retained -= entry.cost } }
        guard !query.isEmpty else { return current }
        var result = Set<String>()
        for (offset, profile) in profiles.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            let entry: Entry
            if let cached = entries[profile.id], cached.matches(profile) { entry = cached }
            else {
                entry = Entry(display: profile.display, email: profile.email, topics: profile.topics,
                    document: profile.display + " " + profile.email + " " + profile.topics.joined(separator: " "))
                if let previous = entries.removeValue(forKey: profile.id) { retained -= previous.cost }
                if entry.cost <= maximumBytes {
                    while !entries.isEmpty && (retained + entry.cost > maximumBytes || entries.count >= 20_000) {
                        guard let id = entries.keys.first, let removed = entries.removeValue(forKey: id) else { break }
                        retained -= removed.cost
                    }
                    entries[profile.id] = entry; retained += entry.cost
                }
            }
            if entry.document.localizedCaseInsensitiveContains(query) { result.insert(profile.id) }
        }
        try Task.checkCancellation()
        return result
    }
    public func retainedBytes() -> Int { retained }
}
