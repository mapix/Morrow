import Foundation
import MorrowCore

/// Called before MobileModel.start() reads the normal workspace or user preferences.
enum MobileAcceptanceMode {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--acceptance-mode") }

    @MainActor static func runIfRequested() async -> Bool {
        guard requested else { return false }
        do {
            guard let request = try AcceptanceRequest.parse() else { return false }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let workspace = request.workspace(in: documents)
            let model = request.modelDirectory ?? Bundle.main.url(forResource: "EmbeddingGemma2-Text", withExtension: nil)
            _ = await AcceptanceHarness().run(mode: request.mode, id: request.id, workspace: workspace, modelDir: model, peerBinding: request.peerBinding)
        } catch {
            // Invalid CLI requests remain opt-in and never fall through into real mail startup.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documents.appendingPathComponent("acceptance-invalid", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let proof: [String: Any] = ["finished": true, "passed": false, "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("request-error.json"), options: .atomic) }
        }
        return true
    }
}
