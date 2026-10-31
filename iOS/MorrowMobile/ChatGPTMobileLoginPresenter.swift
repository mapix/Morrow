import AuthenticationServices
import UIKit
import SwiftUI
import MorrowCore

/// Beta presenter for the existing OSS loopback contract. The browser presents authentication;
/// ChatGPTLoopback alone receives and verifies the exact HTTP callback. No custom URI is registered.
/// Actual-account behavior of this ASWebAuthenticationSession + loopback combination needs device acceptance.
@MainActor
final class ChatGPTMobileLoginPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: UIWindow
    private var session: ASWebAuthenticationSession?
    private var sessionID: UUID?
    private(set) var failure: ChatGPTMobilePresentationError?

    init(anchor: UIWindow?) throws {
        guard let anchor, !anchor.isHidden,
              anchor.windowScene?.activationState == .foregroundActive else {
            throw ChatGPTMobilePresentationError.foregroundRequired
        }
        self.anchor = anchor
        super.init()
    }

    func start(url: URL, onFailure: @escaping @MainActor () -> Void) throws {
        guard session == nil, url.scheme == "https", url.host == "auth.openai.com",
              url.user == nil, url.password == nil,
              anchor.windowScene?.activationState == .foregroundActive else {
            throw ChatGPTMobilePresentationError.foregroundRequired
        }
        let identity = UUID()
        sessionID = identity
        // nil deliberately leaves HTTP navigation to the app-owned loopback listener. Apple's newer
        // .https callback requires an associated HTTPS domain and cannot represent the SIWC HTTP URI.
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == identity else { return }
                let value = error as NSError?
                self.failure = value?.domain == ASWebAuthenticationSessionErrorDomain &&
                    value?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    ? .cancelled : .browserUnavailable
                self.sessionID = nil
                self.session = nil
                onFailure()
            }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        guard browser.canStart, browser.start() else {
            cancel()
            throw ChatGPTMobilePresentationError.browserUnavailable
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func cancel() {
        sessionID = nil
        let browser = session
        session = nil
        browser?.cancel()
    }
}

enum ChatGPTMobilePresentationError: LocalizedError {
    case foregroundRequired, browserUnavailable, cancelled
    var errorDescription: String? {
        switch self {
        case .foregroundRequired:
            return ChatGPTMobileText.text("请在前台打开 Morrow 后开始 ChatGPT 登录。", "Open Morrow in the foreground to start ChatGPT sign-in.", "Morrow を前面に開いてから ChatGPT ログインを開始してください。")
        case .browserUnavailable:
            return ChatGPTMobileText.text("系统登录窗口未能完成授权，请重新登录。", "The system sign-in window did not complete authorization. Please try again.", "システムの認証画面で認証が完了しませんでした。再度ログインしてください。")
        case .cancelled:
            return ChatGPTMobileText.text("ChatGPT 登录已取消。", "ChatGPT sign-in cancelled.", "ChatGPT ログインをキャンセルしました。")
        }
    }
}

/// Captures the window containing the sign-in control, including the correct scene on iPad.
struct ChatGPTMobileLoginAnchor: UIViewRepresentable {
    var onWindow: (UIWindow?) -> Void
    func makeUIView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.onWindow = onWindow
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: WindowReader, context: Context) { uiView.onWindow = onWindow }
    final class WindowReader: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let currentWindow = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(currentWindow) }
        }
    }
}

enum ChatGPTMobileText {
    static func text(_ chinese: String, _ english: String, _ japanese: String) -> String {
        switch UserDefaults.standard.string(forKey: "SmailMobileLanguage") ?? "zh-Hans" {
        case "en": return english
        case "ja": return japanese
        default: return chinese
        }
    }
}
