import Foundation
import SwiftUI
import MorrowCore

@MainActor final class SettingsSaveFeedback: ObservableObject {
    enum Phase: Equatable { case idle, saving, saved, failed(String) }
    enum Scope: Equatable { case general, model }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scope: Scope = .general
    var isSaving: Bool { phase == .saving }
    var failed: Bool { if case .failed = phase { return true }; return false }
    @discardableResult func perform(scope: Scope = .general, _ action: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        self.scope = scope
        phase = .saving
        do { try await action(); phase = .saved; return true }
        catch { phase = .failed(error.localizedDescription); return false }
    }
    func edited() { guard !isSaving else { return }; phase = .idle }
    static func configurationID(_ value: AgentSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value).base64EncodedString()) ?? ""
    }
}

struct SettingsSaveFeedbackView: View {
    @ObservedObject var feedback: SettingsSaveFeedback
    var success: String
    var identifier: String
    var body: some View {
        Group {
            switch feedback.phase {
            case .idle: EmptyView()
            case .saving: HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.t("保存中…")) }
            case .saved: Label(success, systemImage: "checkmark.circle")
            case .failed(let reason): Label(L10n.t("未保存：") + reason, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            }
        }.font(Theme.label).foregroundStyle(feedback.failed ? Theme.error : Theme.secondary).accessibilityIdentifier(identifier)
    }
}
