import SwiftUI
import UIKit
import WebKit
import MorrowCore

struct MobileSecureHTMLView: UIViewRepresentable {
    var document: ReaderDocument
    @Binding var failed: Bool
    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = MobileReaderWebKitContext.store
        configuration.processPool = MobileReaderWebKitContext.pool
        configuration.setURLSchemeHandler(context.coordinator.assets, forURLScheme: "morrow-cid")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        context.coordinator.view = view
        context.coordinator.policyTask = Task { @MainActor [weak coordinator = context.coordinator] in
            let lists = await MobileReaderWebKitContext.lists()
            guard !Task.isCancelled, let coordinator, !coordinator.disposed else { return }
            coordinator.lists = lists; coordinator.ready = true; coordinator.loadPending()
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard !context.coordinator.disposed else { return }
        context.coordinator.failed = $failed; context.coordinator.pending = document; context.coordinator.loadPending()
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.disposed = true; coordinator.policyTask?.cancel(); coordinator.policyTask = nil
        coordinator.pending = nil; coordinator.view = nil; coordinator.failed = .constant(false); coordinator.assets.clear()
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var view: WKWebView?
        var failed: Binding<Bool>
        var ready = false, disposed = false
        var loaded = ""
        var pending: ReaderDocument?
        var policyTask: Task<Void, Never>?
        fileprivate var lists = MobileReaderRuleLists()
        let assets = MobileInlineAssetHandler()
        init(failed: Binding<Bool>) { self.failed = failed }
        func loadPending() {
            guard !disposed, ready, let view, let document = pending else { return }
            pending = nil; guard loaded != document.id else { return }; loaded = document.id
            assets.replace(document)
            view.configuration.userContentController.removeAllContentRuleLists()
            if let list = document.allowsRemoteImages ? (lists.images ?? lists.blocked) : lists.blocked { view.configuration.userContentController.add(list) }
            view.loadHTMLString(document.content, baseURL: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, ["https", "http", "mailto"].contains(scheme) {
                UIApplication.shared.open(url); decisionHandler(.cancel)
            } else if ["about", "data"].contains(scheme) { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        private func report(_ error: Error) { if !disposed, (error as NSError).code != NSURLErrorCancelled { failed.wrappedValue = true } }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

final class MobileInlineAssetHandler: NSObject, WKURLSchemeHandler {
    private var host = ""
    private var assets: [String: ReaderInlineAsset] = [:]
    private var requests: [ObjectIdentifier: UUID] = [:]
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .utility; return q }()
    func replace(_ document: ReaderDocument) { clear(); host = document.host; assets = document.assets }
    func clear() { requests.removeAll(); queue.cancelAllOperations(); assets.removeAll(); host = "" }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == host,
              let id = String(url.path.dropFirst()).removingPercentEncoding, let asset = assets[id] else { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return }
        let key = ObjectIdentifier(urlSchemeTask), token = UUID(); requests[key] = token
        queue.addOperation { [weak self] in
            let bytes: Data?
            if !asset.data.isEmpty { bytes = asset.data.count <= 10 * 1024 * 1024 ? asset.data : nil }
            else if let path = asset.path { bytes = try? BoundedFileReader.read(URL(fileURLWithPath: path), maximumBytes: 10 * 1024 * 1024) }
            else { bytes = nil }
            DispatchQueue.main.async {
                guard let self, self.requests[key] == token else { return }; self.requests.removeValue(forKey: key)
                guard let bytes else { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: asset.mimeType, expectedContentLength: bytes.count, textEncodingName: nil))
                urlSchemeTask.didReceive(bytes); urlSchemeTask.didFinish()
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) }
}

private struct MobileReaderRuleLists: @unchecked Sendable { var blocked: WKContentRuleList?; var images: WKContentRuleList? }
@MainActor private enum MobileReaderWebKitContext {
    static let store = WKWebsiteDataStore.nonPersistent()
    static let pool = WKProcessPool()
    private static var compilation: Task<MobileReaderRuleLists, Never>?
    static func lists() async -> MobileReaderRuleLists {
        if let compilation { return await compilation.value }
        let task = Task { @MainActor in
            let blocked = await compile("MorrowMobileBlockRemoteV1", imageException: false)
            let images = await compile("MorrowMobileImagesOnlyV1", imageException: true)
            return MobileReaderRuleLists(blocked: blocked, images: images)
        }
        compilation = task; return await task.value
    }
    private static func compile(_ id: String, imageException: Bool) async -> WKContentRuleList? {
        let exception = imageException ? ",{\"trigger\":{\"url-filter\":\"^https?://\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}" : ""
        let source = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}" + exception + "]"
        return await withCheckedContinuation { continuation in WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: source) { list, _ in continuation.resume(returning: list) } }
    }
}
