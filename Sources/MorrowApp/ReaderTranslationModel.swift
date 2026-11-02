import SwiftUI
import MorrowCore

@MainActor final class ReaderTranslationModel: ObservableObject {
    @Published private(set) var result: MailTranslation?
    @Published private(set) var isTranslating = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var error: String?
    @Published var showsTranslation = false
    @Published var language = MailTranslationLanguage(rawValue: L10n.languageCode) ?? .english
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var sourceKey: String?
    var isVisible: Bool { isTranslating || result != nil || error != nil }
    func matches(id: String, version: String, subject: String) -> Bool {
        sourceKey == id + "|" + version + "|" + subject + "|" + language.rawValue
    }

    func translate(_ source: ReaderBodySource, subject: String,
        using operation: @escaping @Sendable (String, String, MailTranslationLanguage, @escaping @Sendable (Int, Int) async -> Void, @escaping @Sendable (MailTranslation) async -> Void) async throws -> MailTranslation) {
        let key = source.id + "|" + source.version + "|" + subject + "|" + language.rawValue
        if sourceKey == key, result?.isComplete == true { showsTranslation = true; return }
        reset(); sourceKey = key
        let ticket = generation, target = language
        isTranslating = true
        task = Task {
            do {
                let text = source.translationText
                let translated = try await operation(subject, text, target, { [weak self] completed, total in
                    await self?.updateProgress(completed, total, ticket: ticket)
                }, { [weak self] partial in await self?.updatePartial(partial, ticket: ticket) })
                guard !Task.isCancelled, generation == ticket else { return }
                result = translated; showsTranslation = true; isTranslating = false; task = nil
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                self.error = error.localizedDescription; isTranslating = false; task = nil
            }
        }
    }
    private func updateProgress(_ completed: Int, _ total: Int, ticket: UUID) {
        guard generation == ticket else { return }
        self.completed = completed; self.total = total
    }
    private func updatePartial(_ partial: MailTranslation, ticket: UUID) {
        guard generation == ticket, isTranslating else { return }
        let first = result == nil
        result = partial
        if first { showsTranslation = true }
    }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil; sourceKey = nil
        result = nil; error = nil; isTranslating = false; showsTranslation = false; completed = 0; total = 0
    }
    deinit { task?.cancel() }
}
