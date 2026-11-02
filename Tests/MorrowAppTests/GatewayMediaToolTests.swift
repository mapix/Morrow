import XCTest
import MorrowCore
import SwiftUI
import AVKit
@testable import MorrowApp

private final class AppMediaHTTPFixture: URLProtocol {
    static var count = 0, status = 200, body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class GatewayMediaToolTests: XCTestCase {
    func testNativeVideoPlayerViewLoadsWithoutSwiftUIOverlay() {
        let host = NSHostingView(rootView: AgentVideoPlayer(player: AVPlayer()))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.subviews.isEmpty)
    }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
    private func setup(_ root: URL) async throws -> (AppModel, SDKChatContext) {
        let model = AppModel(root: root, notifications: MediaTestNotifications()); model.settings.enabled = false
        let session = await model.createChatSession()
        let context = SDKChatContext(sessionID: session, instruction: "创作测试", ui: nil, runID: nil, allowedIDs: nil, agreement: nil)
        context.workspaceLease = try await model.sessionWorkspaces.open(session)
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [AppMediaHTTPFixture.self]
        model.gatewayMediaClientOverride = GatewayMediaClient(configuration: try GatewayMediaConfiguration.load(), apiKey: "fixture", network: network)
        AppMediaHTTPFixture.count = 0; AppMediaHTTPFixture.status = 200
        AppMediaHTTPFixture.body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
        return (model, context)
    }
    private func request(_ name: String, call: String, args: [String: OpenUIJSON]) -> OpenUIJSON { .object(["name": .string(name), "callId": .string(call), "args": .object(args)]) }
    func testImageReplayRestoresPreviewWithoutAnotherPaidRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, context) = try await setup(root)
        defer { Task { try? await model.sessionWorkspaces.archive(context.sessionID) } }
        let command = request("generate_image", call: "once", args: ["prompt": .string("blue square")])
        let result = try await model.performSDKTool(command, context: context)
        XCTAssertEqual(context.generatedMedia.count, 1)
        context.generatedMedia = []
        let replay = try await model.performSDKTool(command, context: context)
        XCTAssertEqual(result, replay); XCTAssertEqual(AppMediaHTTPFixture.count, 1); XCTAssertEqual(context.generatedMedia.count, 1)
    }
    func testValidationDoesNotSubmitAndUncertainRequestCannotReplayWithNewID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, context) = try await setup(root)
        defer { Task { try? await model.sessionWorkspaces.archive(context.sessionID) } }
        do { _ = try await model.performSDKTool(request("generate_image", call: "fixable", args: ["prompt": .string("")]), context: context); XCTFail() } catch {}
        XCTAssertEqual(AppMediaHTTPFixture.count, 0)
        AppMediaHTTPFixture.status = 503; AppMediaHTTPFixture.body = Data(#"{"error":{"message":"synthetic unavailable"}}"#.utf8)
        do { _ = try await model.performSDKTool(request("generate_image", call: "fixable", args: ["prompt": .string("blue square")]), context: context); XCTFail() } catch {}
        do { _ = try await model.performSDKTool(request("generate_image", call: "new-id", args: ["prompt": .string("blue square")]), context: context); XCTFail() } catch {}
        XCTAssertEqual(AppMediaHTTPFixture.count, 1)
    }
    func testVideoPollingIsFreshAndRejectsDifferentSessionJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, context) = try await setup(root)
        defer { Task { try? await model.sessionWorkspaces.archive(context.sessionID) } }
        AppMediaHTTPFixture.body = Data(#"{"id":"video_fixture","status":"queued"}"#.utf8)
        _ = try await model.performSDKTool(request("generate_video", call: "create", args: ["prompt": .string("blue square")]), context: context)
        let poll = request("check_media_job", call: "poll", args: ["jobID": .string("video_fixture")])
        _ = try await model.performSDKTool(poll, context: context)
        AppMediaHTTPFixture.body = Data(#"{"id":"video_fixture","status":"in_progress"}"#.utf8)
        let fresh = try await model.performSDKTool(poll, context: context)
        XCTAssertEqual(fresh.object["status"]?.text, "in_progress"); XCTAssertEqual(AppMediaHTTPFixture.count, 3)
        let otherID = await model.createChatSession(), other = SDKChatContext(sessionID: otherID, instruction: "查询", ui: nil, runID: nil, allowedIDs: nil, agreement: nil)
        other.workspaceLease = try await model.sessionWorkspaces.open(otherID)
        do { _ = try await model.performSDKTool(poll, context: other); XCTFail() } catch {}
        XCTAssertEqual(AppMediaHTTPFixture.count, 3)
        try await model.sessionWorkspaces.archive(otherID)
    }
    func testDraftAndSavedMaterialSurviveArchiveWithoutSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, context) = try await setup(root), lease = try XCTUnwrap(context.workspaceLease)
        _ = try await model.sessionWorkspaces.write(png, path: "media/image.png", lease: lease)
        var draft = ComposeDraft(); draft.subject = "synthetic draft"; draft = try await model.persistWorkingDraft(draft)
        context.draftSnapshots[draft.id] = draft
        let result = try await model.performSDKTool(request("attach_workspace_file", call: "attach", args: ["draftID": .string(draft.id), "path": .string("media/image.png")]), context: context)
        XCTAssertEqual(result.object["sent"], .bool(false))
        let preview = AgentWorkspaceMedia(id: "image", name: "image.png", path: "media/image.png", mimeType: "image/png", bytes: png.count, lease: lease)
        try await model.saveWorkspaceMedia(preview)
        try await model.saveWorkspaceMedia(preview)
        let beforeArchive = try await model.store.load(ChatMaterial.self, kind: "chat-material")
        XCTAssertEqual(beforeArchive.count, 1, "Saving the same output again must not create duplicate assets")
        await model.archiveChatSession(context.sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.attachments.first?.data, png); XCTAssertEqual(stored?.state, "draft")
        let materials = try await model.store.load(ChatMaterial.self, kind: "chat-material")
        XCTAssertEqual(try model.chatMaterialData(XCTUnwrap(materials.first)), png)
        let retained = try await model.workspaceMediaData(preview, maximumBytes: 32 * 1024 * 1024)
        XCTAssertEqual(retained, png, "Archived chats can still read deliberately retained material")
    }
    func testConcurrentDraftChangesAndArchiveCancelArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, context) = try await setup(root), lease = try XCTUnwrap(context.workspaceLease)
        _ = try await model.sessionWorkspaces.write(png, path: "media/image.png", lease: lease)
        var draft = ComposeDraft(); draft = try await model.persistWorkingDraft(draft); context.draftSnapshots[draft.id] = draft
        model.composer = draft; model.composer?.body = "user unsaved edit"
        do { _ = try await model.performSDKTool(request("attach_workspace_file", call: "attach", args: ["draftID": .string(draft.id), "path": .string("media/image.png")]), context: context); XCTFail() } catch {}
        XCTAssertEqual(model.composer?.body, "user unsaved edit")
        var cancelled = false
        model.executingSessionID = context.sessionID
        model.sidebarTask = Task { do { try await Task.sleep(for: .seconds(60)) } catch {}; cancelled = Task.isCancelled }
        await model.archiveChatSession(context.sessionID)
        XCTAssertTrue(cancelled); XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
        do { _ = try await model.performSDKTool(request("list_workspace", call: "late", args: [:]), context: context); XCTFail() } catch {}
    }
    func testRunCodeUsesSameSessionWorkspaceAcrossTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let (model, first) = try await setup(root)
        defer { Task { try? await model.sessionWorkspaces.archive(first.sessionID) } }
        let written = try await model.performSDKTool(request("run_code", call: "write", args: ["python": .string("from pathlib import Path\nPath('output/retained.txt').write_text('synthetic session output')\nprint('saved')")]), context: first)
        XCTAssertEqual(written.object["exitCode"]?.text, "0", written.text)
        first.sandbox = nil; first.sandboxDataTask = nil
        let second = SDKChatContext(sessionID: first.sessionID, instruction: "继续", ui: nil, runID: nil, allowedIDs: [], agreement: nil)
        second.workspaceLease = try await model.sessionWorkspaces.open(first.sessionID)
        let read = try await model.performSDKTool(request("run_code", call: "read", args: ["python": .string("from pathlib import Path\nprint(Path('output/retained.txt').read_text())")]), context: second)
        XCTAssertEqual(read.object["exitCode"]?.text, "0", read.text)
        XCTAssertTrue(read.object["stdout"]?.text.contains("synthetic session output") == true)
    }
}
@MainActor private final class MediaTestNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
