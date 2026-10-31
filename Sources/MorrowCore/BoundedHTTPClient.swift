import Foundation

/// Receives delegate chunks under a byte cap. Cancels the actual URLSession
/// task as soon as the response is oversized or its caller is cancelled.
public enum BoundedHTTPClient {
    public static func load(_ request: URLRequest, maximumBytes: Int = 1024 * 1024, errorMaximumBytes: Int = 32 * 1024, configuration supplied: URLSessionConfiguration? = nil) async throws -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0, errorMaximumBytes > 0 else { throw MailError.message("网络响应大小限制无效。") }
        try Task.checkCancellation()
        let configuration = supplied ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(1, min(240, request.timeoutInterval))
        configuration.timeoutIntervalForResource = max(2, min(260, request.timeoutInterval + 10))
        configuration.urlCache = nil
        let receiver = BoundedResponseReceiver(maximumBytes: maximumBytes, errorMaximumBytes: errorMaximumBytes, origin: request.url)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if receiver.begin(continuation) { task.resume() }
            }
        } onCancel: { receiver.cancel(); task.cancel() }
    }
}

private final class BoundedResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let successLimit: Int
    private let errorLimit: Int
    private let origin: URL?
    private var limit: Int
    private var body = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var terminal = false
    init(maximumBytes: Int, errorMaximumBytes: Int, origin: URL?) { successLimit = maximumBytes; errorLimit = errorMaximumBytes; limit = maximumBytes; self.origin = origin }
    func begin(_ value: CheckedContinuation<(Data, HTTPURLResponse), Error>) -> Bool {
        lock.lock()
        if terminal { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value; lock.unlock(); return true
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); guard !terminal else { lock.unlock(); return }; terminal = true
        let caller = continuation; continuation = nil; body = Data(); lock.unlock()
        caller?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive value: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = value as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(MailError.message("模型服务返回了无效 HTTP 响应。"))); return }
        lock.lock(); response = http; limit = (200..<300).contains(http.statusCode) ? successLimit : errorLimit
        let rejected = terminal || (http.expectedContentLength >= 0 && http.expectedContentLength > Int64(limit)); lock.unlock()
        if rejected { completionHandler(.cancel); finish(.failure(MailError.message("模型服务响应超过大小限制，请缩小请求。"))) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); guard !terminal else { lock.unlock(); return }
        let rejected = data.count > limit - body.count
        if !rejected { body.append(data) }
        lock.unlock()
        if rejected { dataTask.cancel(); finish(.failure(MailError.message("模型服务响应超过大小限制，请缩小请求。"))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let value = response.map { (body, $0) }; lock.unlock()
        if let value { finish(.success(value)) } else { finish(.failure(MailError.message("模型服务未返回有效响应。"))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.host?.lowercased() == origin?.host?.lowercased(), request.url?.scheme == origin?.scheme, request.url?.port == origin?.port else {
            completionHandler(nil); task.cancel(); finish(.failure(MailError.message("模型服务重定向到其他地址，请求已停止。"))); return
        }
        completionHandler(request)
    }
}
