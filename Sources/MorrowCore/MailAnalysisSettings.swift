import Foundation

public struct MailAnalysisSettings: Codable, Sendable {
    public var ollamaURL: String
    public var model: String
    public init(ollamaURL: String = "http://127.0.0.1:11434", model: String = "qwen3.5:4b") { self.ollamaURL = ollamaURL; self.model = model }
    public func validated() throws -> Self {
        var value = self
        value.ollamaURL = value.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ModelEndpoint.url(value.ollamaURL, path: "api/chat")
        guard !value.model.isEmpty else { throw MailError.message("请选择邮件分析使用的 Ollama 模型。") }
        return value
    }
    public func applying(to settings: AgentSettings) -> AgentSettings {
        var value = settings
        value.provider = "ollama"; value.ollamaURL = ollamaURL; value.model = model
        return value
    }
}

public extension AgentSettings {
    var mailAnalysisConfiguration: MailAnalysisSettings { mailAnalysis ?? .init(ollamaURL: ollamaURL, model: model) }
    var mailAnalysisModelSettings: Self { mailAnalysisConfiguration.applying(to: self) }
}
