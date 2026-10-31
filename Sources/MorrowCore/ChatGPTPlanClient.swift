import Foundation

/// SIWC uses an account-specific catalog and Responses, independent of API-key gateway configuration.
public actor ChatGPTPlanClient {
    public static let shared = ChatGPTPlanClient()
    private var requests: [UUID: (String, Task<AIResult, Error>)] = [:]
    public init() {}
    public func models(profileID: String) async throws -> [ChatGPTModel] {
        let tokens = try await ChatGPTService.shared.credentials(profileID: profileID)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!); request.timeoutInterval = 25; request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
        let (data, http) = try await BoundedHTTPClient.load(request, maximumBytes: 2 * 1024 * 1024)
        guard http.statusCode == 200 else { throw ChatGPTServiceError.http(data, response: http) }
        struct Catalog: Decodable { var models: [ChatGPTModel] }
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
    }
    public func complete(profileID: String, model: String, system: String, prompt: String, json: Bool, schema: Data?, images: [Data]) async throws -> AIResult {
        guard !model.isEmpty else { throw ChatGPTServiceError("model_missing") }
        let id = UUID()
        let task = Task<AIResult, Error> { let tokens = try await ChatGPTService.shared.credentials(profileID: profileID); return try await Self.infer(token: tokens.accessToken, model: model, system: system, prompt: prompt, json: json, schema: schema, images: images) }
        requests[id] = (profileID, task); defer { requests[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func cancel(profileID: String) { for (_, request) in requests where request.0 == profileID { request.1.cancel() } }
    public static func payload(model: String, system: String, prompt: String, json: Bool, schema: Data?, images: [Data]) throws -> Data {
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        content += images.map { ["type": "input_image", "image_url": "data:image/png;base64," + $0.base64EncodedString()] }
        var instructions = system
        if json { instructions += "\nReturn a single valid JSON object and no other text." }
        var value: [String: Any] = ["model": model, "instructions": instructions, "input": [["role": "user", "content": content]], "store": false, "stream": true]
        if let schema, json { value["text"] = ["format": ["type": "json_schema", "name": "morrow_result", "strict": true, "schema": try JSONSerialization.jsonObject(with: schema)]] }
        else if json { value["text"] = ["format": ["type": "json_object"]] }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private static func infer(token: String, model: String, system: String, prompt: String, json: Bool, schema: Data?, images: [Data]) async throws -> AIResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!); request.httpMethod = "POST"; request.timeoutInterval = 240; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept"); request.httpBody = try payload(model: model, system: system, prompt: prompt, json: json, schema: schema, images: images)
        let (bytes, response) = try await ChatGPTNetwork.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTServiceError("response_failed") }
        guard http.statusCode == 200 else { var data = Data(); for try await byte in bytes { try Task.checkCancellation(); if data.count < 32768 { data.append(byte) } else { break } }; throw ChatGPTServiceError.http(data, response: http) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw ChatGPTServiceError("stream_incomplete") }
        var stream = ChatGPTSSEBytes()
        for try await byte in bytes { try Task.checkCancellation(); if let text = try stream.feed(byte) { return AIResult(text: text, source: "ChatGPT plan / " + model) } }
        throw ChatGPTServiceError("stream_incomplete")
    }
}

/// Parses SSE records (including multiline data) and requires response.completed with a completed status.
public struct ChatGPTResponseStream {
    private var dataLines: [String] = []
    private var output = ""
    private var terminal = false
    private var eventBytes = 0
    private var outputBytes = 0
    private let maximumEventBytes: Int
    private let maximumOutputBytes: Int
    public init(maximumEventBytes: Int = 2 * 1024 * 1024, maximumOutputBytes: Int = 1024 * 1024) {
        self.maximumEventBytes = max(1, maximumEventBytes); self.maximumOutputBytes = max(1, maximumOutputBytes)
    }
    public mutating func feed(line: String) throws -> String? {
        guard !terminal else { throw ChatGPTServiceError("stream_incomplete") }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard data.utf8.count + 1 <= maximumEventBytes - eventBytes else { throw ChatGPTServiceError("response_too_large") }
            eventBytes += data.utf8.count + 1; dataLines.append(data); return nil
        }
        guard line.isEmpty, !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n"); dataLines = []; eventBytes = 0
        if data == "[DONE]" { throw ChatGPTServiceError("stream_incomplete") }
        guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any], let type = object["type"] as? String else { throw ChatGPTServiceError("stream_incomplete") }
        switch type {
        case "response.output_text.delta":
            let delta = object["delta"] as? String ?? ""
            guard delta.utf8.count <= maximumOutputBytes - outputBytes else { throw ChatGPTServiceError("response_too_large") }
            outputBytes += delta.utf8.count; output += delta
        case "response.failed", "error":
            terminal = true; let response = object["response"] as? [String: Any]; let detail = response?["error"] as? [String: Any] ?? object["error"] as? [String: Any]; let code = detail?["code"] as? String ?? object["code"] as? String ?? "response_failed"
            throw ChatGPTServiceError(code.range(of: "^[a-zA-Z0-9_]{1,90}$", options: .regularExpression) == nil ? "response_failed" : code)
        case "response.incomplete": terminal = true; throw ChatGPTServiceError("stream_incomplete")
        case "response.completed":
            terminal = true; guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else { throw ChatGPTServiceError("stream_incomplete") }
            let items = response["output"] as? [[String: Any]] ?? []
            let finalText = items.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            let text = finalText.isEmpty ? output : finalText
            guard !text.isEmpty else { throw ChatGPTServiceError("response_empty") }
            guard text.utf8.count <= maximumOutputBytes else { throw ChatGPTServiceError("response_too_large") }; return text
        default: break
        }
        return nil
    }
}

/// AsyncBytes.lines discards empty lines on Apple platforms. Frame bytes ourselves so SSE record boundaries survive.
public struct ChatGPTSSEBytes {
    private var line = Data()
    private var skipLF = false
    private var records = ChatGPTResponseStream()
    private var receivedBytes = 0
    private let maximumStreamBytes: Int
    private let maximumLineBytes: Int
    public init(maximumStreamBytes: Int = 8 * 1024 * 1024, maximumLineBytes: Int = 2 * 1024 * 1024) {
        self.maximumStreamBytes = max(1, maximumStreamBytes); self.maximumLineBytes = max(1, maximumLineBytes)
    }
    public mutating func feed(_ byte: UInt8) throws -> String? {
        guard receivedBytes < maximumStreamBytes else { throw ChatGPTServiceError("response_too_large") }; receivedBytes += 1
        if byte == 10, skipLF { skipLF = false; return nil }
        skipLF = false
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            guard let text = String(data: line, encoding: .utf8) else { throw ChatGPTServiceError("stream_incomplete") }
            line.removeAll(keepingCapacity: true)
            return try records.feed(line: text)
        }
        guard line.count < maximumLineBytes else { throw ChatGPTServiceError("response_too_large") }; line.append(byte)
        return nil
    }
}
