import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GatewayMediaModel: Codable, Sendable, Equatable {
    public let id: String
    public let capability: String
    public let enabled: Bool
    public let note: String?
}
public struct GatewayMediaConfiguration: Codable, Sendable {
    public let baseURL: String
    public let verifiedAt: String
    public let defaultImageModel: String
    public let defaultVideoModel: String
    public let defaultVideoUnderstandingModel: String
    public let models: [GatewayMediaModel]
    public static func load(path: URL? = nil) throws -> Self {
        let candidates = [path, Bundle.main.resourceURL?.appendingPathComponent("media-models.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("configuration/media-models.json")].compactMap { $0 }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw MailError.message("媒体模型配置文件不可用。") }
        let config = try JSONDecoder().decode(Self.self, from: BoundedFileReader.read(file, maximumBytes: 128 * 1024))
        _ = try ModelEndpoint.url(config.baseURL, path: "models")
        return config
    }
    public func require(_ id: String, capability: String) throws -> GatewayMediaModel {
        guard let model = models.first(where: { $0.id == id && $0.capability == capability && $0.enabled }) else { throw MailError.message("该媒体模型未获配置授权或用途不匹配。请先使用list_media_models确认实际模型。") }
        return model
    }
}
private typealias GatewayHTTPResponse = (data: Data, response: HTTPURLResponse)

public struct GatewayMediaOutput: Sendable {
    public let data: Data
    public let mimeType: String
    public let model: String
    public let costUSD: Double?
}
public struct GatewayVideoAnalysis: Sendable {
    public let text: String
    public let costUSD: Double?
}

/// Native host owns the API key. Prompts/files go only to the configured media
/// gateway; generated URL downloads never receive its authorization header.
public struct GatewayMediaClient: Sendable {
    public let configuration: GatewayMediaConfiguration
    private let apiKey: String
    private let network: URLSessionConfiguration
    public init(configuration: GatewayMediaConfiguration, apiKey: String, network: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration; self.apiKey = apiKey; self.network = network
    }
    private func load(path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", idempotencyKey: String? = nil,
                      maximumBytes: Int = 64 * 1024 * 1024, gatewayRoot: Bool = false) async throws -> GatewayHTTPResponse {
        var target = try ModelEndpoint.url(configuration.baseURL, path: path)
        if gatewayRoot {
            var components = URLComponents(url: try ModelEndpoint.url(configuration.baseURL, path: "models"), resolvingAgainstBaseURL: false)!
            components.path = "/" + path; target = components.url!
        }
        var request = URLRequest(url: target); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = method == "GET" ? 60 : 240
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if gatewayRoot { request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision") }
        let (data, response) = try await BoundedHTTPClient.load(request, maximumBytes: maximumBytes, configuration: network)
        let result: GatewayHTTPResponse = (data, response)
        guard (200...299).contains(result.response.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
            let message = (obj?["error"] as? [String: Any])?["message"] as? String
            let sanitized = (message ?? "请求失败").replacingOccurrences(of: apiKey, with: "[redacted]")
            throw MailError.message("媒体网关 HTTP \(result.response.statusCode)：" + String(sanitized.prefix(500)))
        }
        return result
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailError.message("媒体网关返回格式无效。") }; return value
    }
    public func availableModels() async throws -> Set<String> {
        let response = try await load(path: "models", maximumBytes: 2 * 1024 * 1024)
        return Set((try object(response.data)["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }
    public static func imageMIME(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
              let mime = UTType(identifier as String)?.preferredMIMEType, ["image/png", "image/jpeg", "image/webp"].contains(mime),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 64_000_000 else { throw MailError.message("请选择有效的PNG、JPEG或WebP图片（最多6400万像素）。") }
        return mime
    }
    public func validateImage(model: String, prompt: String, size: String, quality: String, images: [Data]) throws {
        _ = try configuration.require(model, capability: "image_generation")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 16_000,
              ["auto", "1024x1024", "1536x1024", "1024x1536"].contains(size), ["auto", "low", "medium", "high", "xhigh", "max"].contains(quality), images.count <= 4,
              images.allSatisfy({ $0.count <= 20 * 1024 * 1024 }) else { throw MailError.message("图片生成参数超出允许范围。") }
        for image in images { _ = try Self.imageMIME(image) }
    }
    public func generateImage(model: String, prompt: String, size: String = "1024x1024", quality: String = "auto", images: [Data] = [], idempotencyKey: String) async throws -> GatewayMediaOutput {
        try validateImage(model: model, prompt: prompt, size: size, quality: quality, images: images)
        let response: GatewayHTTPResponse
        if images.isEmpty {
            var value: [String: Any] = ["model": model, "prompt": prompt, "n": 1, "size": size, "response_format": "b64_json"]
            if model.hasPrefix("gpt-image") { value["quality"] = quality }
            response = try await load(path: "images/generations", method: "POST", body: JSONSerialization.data(withJSONObject: value), idempotencyKey: idempotencyKey)
        } else {
            var fields = ["model": model, "prompt": prompt, "n": "1", "size": size, "response_format": "b64_json"]
            if model.hasPrefix("gpt-image") { fields["quality"] = quality }
            let form = MediaMultipart(fields: fields, files: try images.enumerated().map {
                let mime = try Self.imageMIME($0.element)
                return .init(field: "image[]", name: "reference-\($0.offset)." + (mime == "image/jpeg" ? "jpg" : mime == "image/webp" ? "webp" : "png"), mime: mime, data: $0.element)
            })
            response = try await load(path: "images/edits", method: "POST", body: form.data, contentType: form.contentType, idempotencyKey: idempotencyKey)
        }
        guard let row = (try object(response.data)["data"] as? [[String: Any]])?.first else { throw MailError.message("图片网关没有返回生成结果。") }
        let data: Data
        if let base64 = row["b64_json"] as? String, let decoded = Data(base64Encoded: base64) { data = decoded }
        else if let address = row["url"] as? String { data = try await downloadPublicURL(address, maximumBytes: 64 * 1024 * 1024) }
        else { throw MailError.message("图片生成结果缺少文件数据。") }
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw MailError.message("生成图片大小无效。") }
        let mime = try Self.imageMIME(data)
        return .init(data: data, mimeType: mime, model: model, costUSD: response.response.value(forHTTPHeaderField: "x-litellm-response-cost").flatMap(Double.init))
    }
    public func validateVideo(model: String, prompt: String, seconds: Int, size: String, reference: Data?) throws {
        _ = try configuration.require(model, capability: "video_generation")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 16_000, [4, 6, 8].contains(seconds), ["1280x720", "720x1280"].contains(size), (reference?.count ?? 0) <= 20 * 1024 * 1024 else { throw MailError.message("视频生成参数超出允许范围。") }
        if let reference { _ = try Self.imageMIME(reference) }
    }
    public func createVideo(model: String, prompt: String, seconds: Int = 4, size: String = "1280x720", reference: Data? = nil, idempotencyKey: String) async throws -> OpenUIJSON {
        try validateVideo(model: model, prompt: prompt, seconds: seconds, size: size, reference: reference)
        let files: [MediaMultipart.File] = try reference.map {
            let mime = try Self.imageMIME($0)
            return [MediaMultipart.File(field: "input_reference", name: "reference." + (mime == "image/jpeg" ? "jpg" : mime == "image/webp" ? "webp" : "png"), mime: mime, data: $0)]
        } ?? []
        let form = MediaMultipart(fields: ["model": model, "prompt": prompt, "seconds": String(seconds), "size": size], files: files)
        let result = try await load(path: "videos", method: "POST", body: form.data, contentType: form.contentType, idempotencyKey: idempotencyKey, maximumBytes: 2 * 1024 * 1024)
        var job: [String: OpenUIJSON] = try JSONDecoder().decode(OpenUIJSON.self, from: result.data).object
        if let cost = result.response.value(forHTTPHeaderField: "x-litellm-response-cost").flatMap(Double.init) { job["costUSD"] = .number(cost) }
        return .object(job)
    }
    private func validVideoID(_ id: String) throws -> String {
        guard !id.isEmpty, id.utf8.count <= 4096, id.range(of: #"^[A-Za-z0-9_+=-]+$"#, options: .regularExpression) != nil else { throw MailError.message("视频任务标识无效。") }; return id
    }
    public func videoStatus(_ id: String) async throws -> OpenUIJSON {
        let result = try await load(path: "videos/" + validVideoID(id), maximumBytes: 2 * 1024 * 1024)
        return try JSONDecoder().decode(OpenUIJSON.self, from: result.data)
    }
    public func videoContent(_ id: String) async throws -> GatewayMediaOutput {
        let result = try await load(path: "videos/" + validVideoID(id) + "/content", maximumBytes: 128 * 1024 * 1024)
        guard result.data.count > 12, String(decoding: result.data[4..<8], as: UTF8.self) == "ftyp" else { throw MailError.message("视频网关未返回有效MP4文件；保留任务ID，可稍后继续查询。") }
        return .init(data: result.data, mimeType: "video/mp4", model: "", costUSD: nil)
    }
    public func analyzeVideo(model: String, prompt: String, data: Data, mimeType: String = "video/mp4") async throws -> GatewayVideoAnalysis {
        _ = try configuration.require(model, capability: "video_understanding")
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024, ["video/mp4", "video/webm", "video/quicktime"].contains(mimeType), prompt.utf8.count <= 16_000 else { throw MailError.message("视频理解输入超过限制。") }
        let value: [String: Any] = ["model": model, "custom_llm_provider": "vertex_ai", "stream": false, "store": false,
            "generation_config": ["max_output_tokens": 1800, "thinking_level": "low"],
            "input": [["type": "user_input", "content": [
                ["type": "text", "text": prompt], ["type": "video", "mime_type": mimeType, "data": data.base64EncodedString()]]]]]
        let result = try await load(path: "v1beta/interactions", method: "POST", body: JSONSerialization.data(withJSONObject: value), maximumBytes: 2 * 1024 * 1024, gatewayRoot: true)
        let response = try object(result.data)
        let blocks = (response["steps"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "model_output" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = (blocks + (response["outputs"] as? [[String: Any]] ?? [])).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("视频理解模型没有返回文本结果。") }
        return .init(text: text, costUSD: result.response.value(forHTTPHeaderField: "x-litellm-response-cost").flatMap(Double.init))
    }
    private func downloadPublicURL(_ address: String, maximumBytes: Int) async throws -> Data {
        guard let url = URL(string: address), url.scheme == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              host == URL(string: configuration.baseURL)?.host?.lowercased() || ["blob.core.windows.net", "storage.googleapis.com", "googleusercontent.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw MailError.message("生成文件下载地址不属于已支持的媒体服务。") }
        let (data, response) = try await BoundedHTTPClient.load(URLRequest(url: url), maximumBytes: maximumBytes, configuration: network)
        guard response.statusCode == 200 else { throw MailError.message("生成文件下载未完成。") }; return data
    }
}

struct MediaMultipart {
    struct File { let field: String; let name: String; let mime: String; let data: Data }
    let data: Data
    let contentType: String
    init(fields: [String: String], files: [File]) {
        let boundary = "Morrow-" + UUID().uuidString; var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for file in files {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\nContent-Type: \(file.mime)\r\n\r\n".utf8)); body.append(file.data); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8)); data = body; contentType = "multipart/form-data; boundary=" + boundary
    }
}
