import Foundation

public struct AgentModelToolCall: Codable, Sendable {
    public var id: String
    public var name: String
    public var args: OpenUIJSON
    public var type = "tool_call"
}
public struct AgentModelResponse: Codable, Sendable {
    public var content: String
    public var toolCalls: [AgentModelToolCall]
    public var model: String
    public var finishReason: String
    public var usage: OpenUIJSON?
    public var replay: [OpenUIJSON]?
    public var timing: OpenUIJSON?
    public func json() throws -> OpenUIJSON { try JSONDecoder().decode(OpenUIJSON.self, from: JSONEncoder().encode(self)) }
}

/// Provider transport for SDK-native function calls. It has no planning loop.
/// Secrets stay in the Swift host; the SDK receives model output and tool data.
public actor AgentToolModel {
    private let configuration: URLSessionConfiguration?
    private let ai: AIEngine
    public init(configuration: URLSessionConfiguration? = nil) { self.configuration = configuration; ai = AIEngine(httpConfiguration: configuration) }
    public func respond(_ input: OpenUIJSON, settings: AgentSettings, images: [Data] = [], priority: AIRequestPriority = .interactive,
        delta: @escaping @Sendable (String) async throws -> Void) async throws -> AgentModelResponse {
        guard settings.enabled else { throw MailError.message("伙伴已暂停，请在设置中启用。") }
        let queuedAt = Date()
        return try await NetworkOperationGate.inference.withPermit(priority: priority) {
            let startedAt = Date()
            var response = try await self.request(input, settings: settings, images: images, delta: delta)
            var timing = response.timing?.object ?? [:]
            timing["queueMs"] = .number(startedAt.timeIntervalSince(queuedAt) * 1000); timing["requestMs"] = .number(Date().timeIntervalSince(startedAt) * 1000)
            response.timing = .object(timing); return response
        }
    }
    private func request(_ input: OpenUIJSON, settings: AgentSettings, images: [Data], delta: @escaping @Sendable (String) async throws -> Void) async throws -> AgentModelResponse {
        let fields = input.object
        guard case .array(let messages) = fields["messages"], case .array(let tools) = fields["tools"], messages.count <= 256, tools.count <= 128,
            try JSONEncoder().encode(input).count <= 256 * 1024 else { throw MailError.message("Agent 模型上下文超过请求预算，请压缩会话后继续。") }
        let maxTokens = min(3000, max(256, Int(fields["maxTokens"]?.text ?? "1800") ?? 1800))
        guard images.count <= 8, images.allSatisfy({ $0.count <= 8 * 1024 * 1024 }), images.reduce(0, { $0 + $1.count }) <= 16 * 1024 * 1024 else { throw MailError.message("本轮图片超过模型请求预算。") }
        if settings.provider == "chatgpt" { return try await chatGPT(messages: messages, tools: tools, images: images, settings: settings, delta: delta) }
        if settings.provider == "apple" { throw MailError.message("当前 SDK 工具引擎需要支持原生工具调用的模型，请选择 Ollama、兼容接口或 GPT 登录模型。") }
        var model = settings.model
        if settings.provider == "auto" {
            let names = try await ai.availableModels(endpoint: settings.ollamaURL)
            guard names.contains(model) else { throw MailError.message("配置的本地模型尚未安装；Agent 不会自动切换到其他模型。") }
        }
        let compatible = settings.provider == "openai"
        if compatible { model = settings.openAIModel ?? settings.model }
        let endpoint = compatible ? settings.openAIURL ?? "https://api.openai.com/v1" : settings.ollamaURL
        let url = try ModelEndpoint.url(endpoint, path: compatible ? "chat/completions" : "api/chat")
        var providerMessages = compatible ? messages : try Self.ollamaMessages(messages)
        if compatible && settings.useDeveloperRole == true { providerMessages = providerMessages.map { var value = $0.object; if value["role"]?.text == "system" { value["role"] = .string("developer") }; return .object(value) } }
        if !images.isEmpty, let index = providerMessages.lastIndex(where: { $0.object["role"]?.text == "user" }) {
            var value = providerMessages[index].object
            if compatible {
                value["content"] = .array([.object(["type": .string("text"), "text": value["content"] ?? .string("")])] + images.map { .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/png;base64," + $0.base64EncodedString())])]) })
            } else { value["images"] = .array(images.map { .string($0.base64EncodedString()) }) }
            providerMessages[index] = .object(value)
        }
        var payload: [String: Any] = ["model": model, "stream": true, "messages": try foundation(.array(providerMessages))]
        if !tools.isEmpty { payload["tools"] = try foundation(.array(tools)) }
        if compatible {
            payload["max_completion_tokens"] = maxTokens
            payload["stream_options"] = ["include_usage": true]
            if !tools.isEmpty { payload["tool_choice"] = fields["toolChoice"]?.text ?? "auto" }
        } else { payload["think"] = false; payload["options"] = ["temperature": 0.2, "num_ctx": 16384, "num_predict": maxTokens] }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if compatible, let key = try? SecretStore.read(accountID: ModelEndpoint.credentialID(endpoint)), !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let session = configuration.map { URLSession(configuration: $0) } ?? ChatGPTNetwork.session
        defer { if configuration != nil { session.invalidateAndCancel() } }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { if errorData.count == 32768 { break }; errorData.append(byte) }
            let object = (try? JSONDecoder().decode(OpenUIJSON.self, from: errorData))?.object ?? [:]
            let reason = object["error"]?.object["message"]?.text ?? object["error"]?.text ?? ""
            throw MailError.message("Agent 模型接口未接受请求（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，\(model)）：" + String(reason.prefix(300)))
        }
        var accumulator = AgentModelStream(compatible: compatible), framer = AgentModelLines()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let line = try framer.feed(byte) {
                if let text = try accumulator.feed(line), !text.isEmpty { try await delta(text) }
            }
        }
        return try accumulator.result(model: model)
    }
    private func foundation(_ value: OpenUIJSON) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
    public static func ollamaMessages(_ messages: [OpenUIJSON]) throws -> [OpenUIJSON] {
        var names: [String: String] = [:], result: [OpenUIJSON] = []
        for message in messages {
            var fields = message.object
            if case .array(let blocks) = fields["content"] {
                fields["content"] = .string(blocks.filter { $0.object["type"]?.text == "text" }.compactMap { $0.object["text"]?.text }.joined(separator: "\n"))
            }
            if case .array(let calls) = fields["tool_calls"] {
                fields["tool_calls"] = .array(try calls.map { call in
                    var value = call.object, function = value["function"]?.object ?? [:]
                    if let id = value["id"]?.text { names[id] = function["name"]?.text ?? "" }
                    if case .string(let args) = function["arguments"] { function["arguments"] = try JSONDecoder().decode(OpenUIJSON.self, from: Data(args.utf8)) }
                    value["function"] = .object(function); return .object(value)
                })
            }
            if let id = fields["tool_call_id"]?.text, let name = names[id] { fields["tool_name"] = .string(name) }
            fields.removeValue(forKey: "providerItems"); result.append(.object(fields))
        }
        return result
    }
    private func chatGPT(messages: [OpenUIJSON], tools: [OpenUIJSON], images: [Data], settings: AgentSettings,
        delta: @escaping @Sendable (String) async throws -> Void) async throws -> AgentModelResponse {
        guard let profileID = settings.chatGPTAccountID else { throw ChatGPTServiceError("not_signed_in") }
        let credentials = try await ChatGPTService.shared.credentials(profileID: profileID), model = settings.chatGPTModel ?? ""
        guard !model.isEmpty else { throw ChatGPTServiceError("model_missing") }
        let payload = try Self.responsesPayload(messages: messages, tools: tools, model: model, images: images)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.httpBody = payload; request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await ChatGPTNetwork.session.bytes(for: request); defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw MailError.message("GPT Agent 模型请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。") }
        var framer = AgentModelLines(), terminal: AgentModelResponse?
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = try framer.feed(byte), line.hasPrefix("data:") else { continue }
            let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            guard let value = try? JSONDecoder().decode(OpenUIJSON.self, from: data) else { continue }
            switch value.object["type"]?.text {
            case "response.output_text.delta": try await delta(value.object["delta"]?.text ?? "")
            case "response.completed": terminal = try Self.responsesResult(value.object["response"] ?? .null, model: model)
            case "response.failed", "response.incomplete", "error": throw MailError.message("GPT Agent 模型未完成响应，已保存会话状态。")
            default: break
            }
            if terminal != nil { break }
        }
        guard let terminal else { throw MailError.message("GPT Agent 响应流中断，已保存会话状态。") }; return terminal
    }
    public static func responsesPayload(messages: [OpenUIJSON], tools: [OpenUIJSON], model: String, images: [Data] = []) throws -> Data {
        var instructions: [String] = [], input: [OpenUIJSON] = []
        for message in messages {
            let fields = message.object, role = fields["role"]?.text ?? "user", content = fields["content"]?.text ?? ""
            if role == "system" || role == "developer" { instructions.append(content); continue }
            if role == "assistant", case .array(let items) = fields["providerItems"], !items.isEmpty { input.append(contentsOf: items); continue }
            if role == "tool" {
                input.append(.object(["type": .string("function_call_output"), "call_id": fields["tool_call_id"] ?? .null, "output": .string(content)])); continue
            }
            if !content.isEmpty { input.append(.object(["role": .string(role), "content": .string(content)])) }
            if case .array(let calls) = fields["tool_calls"] {
                for call in calls {
                    let value = call.object, function = value["function"]?.object ?? [:]
                    input.append(.object(["type": .string("function_call"), "call_id": value["id"] ?? .null, "name": function["name"] ?? .null, "arguments": function["arguments"] ?? .string("{}")]))
                }
            }
        }
        let definitions = tools.map { tool -> OpenUIJSON in
            var function = tool.object["function"]?.object ?? [:]; function["type"] = .string("function"); function["strict"] = .bool(false); return .object(function)
        }
        if !images.isEmpty, let index = input.lastIndex(where: { $0.object["role"]?.text == "user" }) {
            var message = input[index].object
            message["content"] = .array([.object(["type": .string("input_text"), "text": message["content"] ?? .string("")])] + images.map { .object(["type": .string("input_image"), "image_url": .string("data:image/png;base64," + $0.base64EncodedString())]) })
            input[index] = .object(message)
        }
        return try JSONEncoder().encode(OpenUIJSON.object(["model": .string(model), "instructions": .string(instructions.joined(separator: "\n")), "input": .array(input), "tools": .array(definitions), "store": .bool(false), "stream": .bool(true), "include": .array([.string("reasoning.encrypted_content")])]))
    }
    public static func responsesResult(_ response: OpenUIJSON, model: String) throws -> AgentModelResponse {
        guard response.object["status"]?.text == "completed", case .array(let output) = response.object["output"] else { throw MailError.message("GPT Agent 执行方案未完成。") }
        var text = "", calls: [AgentModelToolCall] = []
        for item in output {
            let fields = item.object
            if fields["type"]?.text == "message", case .array(let content) = fields["content"] {
                text += content.filter { $0.object["type"]?.text == "output_text" }.compactMap { $0.object["text"]?.text }.joined()
            } else if fields["type"]?.text == "function_call" {
                calls.append(try AgentModelStream.call(id: fields["call_id"]?.text, name: fields["name"]?.text ?? "", arguments: fields["arguments"] ?? .string("{}")))
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { throw MailError.message("GPT Agent 模型没有返回文本或工具调用。") }
        return .init(content: text, toolCalls: calls, model: model, finishReason: calls.isEmpty ? "stop" : "tool_calls", replay: output)
    }
}

public struct AgentModelStream {
    private let compatible: Bool
    private var text = "", calls: [Int: (String, String, String)] = [:], localCalls: [AgentModelToolCall] = []
    private var finish = "", complete = false, outputBytes = 0
    private var timing: [String: OpenUIJSON] = [:]
    private var usage: OpenUIJSON?
    public init(compatible: Bool) { self.compatible = compatible }
    public mutating func feed(_ line: String) throws -> String? {
        if line.isEmpty || line.hasPrefix(":") || line.hasPrefix("event:") { return nil }
        let raw = compatible ? String(line.hasPrefix("data:") ? line.dropFirst(5) : Substring(line)).trimmingCharacters(in: .whitespaces) : line
        if raw == "[DONE]" { return nil }
        guard let data = raw.data(using: .utf8), let reply = try? JSONDecoder().decode(OpenUIJSON.self, from: data) else { throw MailError.message("Agent 模型返回了无效的响应记录。") }
        let fields = reply.object
        if let value = fields["usage"], value != .null { usage = value; timing["outputTokens"] = value.object["completion_tokens"] ?? value.object["output_tokens"] }
        if fields["error"] != nil { throw MailError.message("本地 Agent 模型未完成工具调用。") }
        var content = ""
        if compatible {
            guard case .array(let choices) = fields["choices"], let first = choices.first else { return nil }
            let value = first.object, message = value["delta"]?.object ?? value["message"]?.object ?? [:]
            content = message["content"]?.text ?? ""
            if case .array(let updates) = message["tool_calls"] {
                for call in updates {
                    let item = call.object, index = Int(item["index"]?.text ?? "0") ?? 0, function = item["function"]?.object ?? [:]
                    var current = calls[index] ?? ("", "", "")
                    if let id = item["id"]?.text, !id.isEmpty { current.0 = id }
                    current.1 += function["name"]?.text ?? ""; current.2 += function["arguments"]?.text ?? ""; calls[index] = current
                }
            }
            if let reason = value["finish_reason"], reason != .null { finish = reason.text; complete = true }
        } else {
            let message = fields["message"]?.object ?? [:]; content = message["content"]?.text ?? ""
            if case .array(let updates) = message["tool_calls"] {
                for update in updates {
                    let value = update.object, function = value["function"]?.object ?? [:]
                    localCalls.append(try Self.call(id: value["id"]?.text, name: function["name"]?.text ?? "", arguments: function["arguments"] ?? .object([:])))
                }
            }
            if fields["done"] == .bool(true) {
                finish = fields["done_reason"]?.text ?? "stop"; complete = true
                for (source, target) in [("load_duration", "loadMs"), ("prompt_eval_duration", "promptMs"), ("eval_duration", "generationMs"), ("total_duration", "serverMs")] { if let value = Double(fields[source]?.text ?? "") { timing[target] = .number(value / 1_000_000) } }
                timing["outputTokens"] = fields["eval_count"]
                if let input = fields["prompt_eval_count"], let output = fields["eval_count"] { usage = .object(["input_tokens": input, "output_tokens": output]) }
            }
        }
        outputBytes += content.utf8.count
        guard outputBytes <= 1024 * 1024, calls.count <= 16, localCalls.count <= 16 else { throw MailError.message("Agent 模型输出超过预算。") }
        text += content; return content.isEmpty ? nil : content
    }
    public func result(model: String) throws -> AgentModelResponse {
        guard complete, finish != "length" else { throw MailError.message("Agent 模型响应未完成或被截断；会话状态已保存。") }
        let values = compatible ? try calls.keys.sorted().map { index in let value = calls[index]!; return try Self.call(id: value.0, name: value.1, arguments: .string(value.2)) } : localCalls
        guard !text.isEmpty || !values.isEmpty else { throw MailError.message("Agent 模型没有返回文本或工具调用。") }
        return .init(content: text, toolCalls: values, model: model, finishReason: values.isEmpty ? "stop" : "tool_calls", usage: usage, timing: .object(timing))
    }
    static func call(id: String?, name: String, arguments: OpenUIJSON) throws -> AgentModelToolCall {
        guard !name.isEmpty, name.utf8.count <= 128 else { throw MailError.message("Agent 工具名称无效。") }
        let args: OpenUIJSON
        if case .string(let value) = arguments { args = try JSONDecoder().decode(OpenUIJSON.self, from: Data(value.utf8)) } else { args = arguments }
        guard case .object = args else { throw MailError.message("Agent 工具参数无效。") }
        return .init(id: id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString, name: name, args: args)
    }
}

private struct AgentModelLines {
    private var line = Data(), skipLF = false, total = 0
    mutating func feed(_ byte: UInt8) throws -> String? {
        total += 1; guard total <= 8 * 1024 * 1024 else { throw MailError.message("Agent 模型响应流超过大小预算。") }
        if byte == 10 && skipLF { skipLF = false; return nil }; skipLF = false
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            guard let text = String(data: line, encoding: .utf8) else { throw MailError.message("Agent 模型响应编码无效。") }
            line.removeAll(keepingCapacity: true); return text
        }
        guard line.count < 1024 * 1024 else { throw MailError.message("Agent 模型响应记录过大。") }; line.append(byte); return nil
    }
}
