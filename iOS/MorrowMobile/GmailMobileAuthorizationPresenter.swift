import AuthenticationServices
import UIKit
import SwiftUI

@MainActor
final class GmailMobileAuthorizationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: UIWindow
    private var session: ASWebAuthenticationSession?
    private var gate: GmailMobileAuthorizationGate?
    private var timeoutTask: Task<Void, Never>?

    init(anchor: UIWindow?) throws {
        guard let anchor, !anchor.isHidden, anchor.windowScene?.activationState == .foregroundActive else {
            throw GmailMobileAuthorizationError.foregroundRequired
        }
        self.anchor = anchor
        super.init()
    }

    func authorize(url: URL, attempt: GmailMobileOAuthAttempt) async throws -> String {
        guard session == nil, url.scheme == "https", url.host == "accounts.google.com",
              url.user == nil, url.password == nil, url.path == "/o/oauth2/v2/auth",
              anchor.windowScene?.activationState == .foregroundActive else {
            throw GmailMobileAuthorizationError.foregroundRequired
        }
        let pending = GmailMobileAuthorizationGate()
        gate = pending
        defer { timeoutTask?.cancel(); timeoutTask = nil; session = nil; gate = nil }
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                guard !Task.isCancelled else { pending.finish(.failure(CancellationError())); return }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: attempt.client.callbackScheme) { callback, error in
                    if let value = error as NSError? {
                        let cancelled = value.domain == ASWebAuthenticationSessionErrorDomain && value.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                        pending.finish(.failure(cancelled ? GmailMobileAuthorizationError.cancelled : GmailMobileAuthorizationError.browserUnavailable))
                    } else if let callback {
                        pending.finish(.success(callback))
                    } else {
                        pending.finish(.failure(GmailMobileAuthorizationError.invalidCallback))
                    }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                session = browser
                guard browser.canStart, browser.start() else {
                    browser.cancel()
                    pending.finish(.failure(GmailMobileAuthorizationError.browserUnavailable))
                    return
                }
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    if pending.finish(.failure(GmailMobileAuthorizationError.timedOut)) { self?.session?.cancel() }
                }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
            Task { @MainActor [weak self] in self?.session?.cancel() }
        }
        try Task.checkCancellation()
        return try attempt.authorizationCode(from: callback)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func cancel() {
        gate?.finish(.failure(CancellationError()))
        timeoutTask?.cancel(); timeoutTask = nil
        session?.cancel()
        session = nil
    }
}

private final class GmailMobileAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func install(_ value: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }

    @discardableResult func finish(_ value: Result<URL, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
        return true
    }
}

struct GmailMobileAuthorizationAnchor: UIViewRepresentable {
    var onWindow: (UIWindow?) -> Void
    func makeUIView(context: Context) -> WindowReader {
        let view = WindowReader(); view.onWindow = onWindow; view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ uiView: WindowReader, context: Context) { uiView.onWindow = onWindow }
    final class WindowReader: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let current = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(current) }
        }
    }
}
