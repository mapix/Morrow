import XCTest
import MorrowCore
@testable import MorrowApp

/// Explicitly opted in acceptance. Stable native receipts prevent resubmission
/// after interruption. No real mail, attachments, contacts or model chat used.
@MainActor final class GatewayMediaLiveTests: XCTestCase {
    func testApprovedUnderstandingUsesExistingSyntheticClip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MORROW_LIVE_VIDEO_UNDERSTANDING"] == "1", let path = env["MORROW_LIVE_MEDIA_EVIDENCE"], let key = env["LEARNINGS_API_KEY"] else { throw XCTSkip("Existing synthetic clip understanding requires explicit paid acceptance opt-in") }
        let evidence = URL(fileURLWithPath: path), marker = evidence.appendingPathComponent("native-video-understanding-submitted")
        guard !FileManager.default.fileExists(atPath: marker.path) else { throw XCTSkip("Existing understanding attempt preserved; no duplicate inference submitted") }
        var budget = try JSONDecoder().decode(OpenUIJSON.self, from: Data(contentsOf: evidence.appendingPathComponent("acceptance.json"))).object
        let previous = Double(budget["totalUSD"]?.text ?? "5") ?? 5
        guard previous + 0.10 <= 5 else { throw MailError.message("Acceptance budget is exhausted") }
        let model = AppModel(root: evidence.appendingPathComponent("runtime"), notifications: LiveMediaNotifications()); model.settings.enabled = false
        model.gatewayMediaClientOverride = GatewayMediaClient(configuration: try GatewayMediaConfiguration.load(), apiKey: key)
        let session = "approved-media-2026-11-02", context = SDKChatContext(sessionID: session, instruction: "描述已生成的虚构视频", ui: nil, runID: nil, allowedIDs: [], agreement: nil)
        model.chatSessions = [ChatSession(id: session)]; context.workspaceLease = try await model.sessionWorkspaces.open(session)
        let lease = try XCTUnwrap(context.workspaceLease), clip = try Data(contentsOf: evidence.appendingPathComponent("video.mp4"))
        _ = try await model.sessionWorkspaces.write(clip, path: "media/understanding.mp4", lease: lease)
        try Data("One authorized native Interactions request".utf8).write(to: marker, options: .atomic)
        let result = try await model.performSDKTool(.object(["name": .string("analyze_video"), "callId": .string("approved-understanding-one"), "args": .object(["path": .string("media/understanding.mp4"), "prompt": .string("Describe the visible object and its motion in this short synthetic video in one sentence."), "model": .string("gemini-omni-flash")])]), context: context)
        XCTAssertFalse(result.object["text"]?.text.isEmpty ?? true)
        try JSONEncoder().encode(result).write(to: evidence.appendingPathComponent("native-video-understanding.json"), options: .atomic)
        let cost = Double(result.object["costUSD"]?.text ?? "")
        budget["videoUnderstandingCostUSD"] = cost.map { .number($0) } ?? .null
        budget["totalUSD"] = .number(previous + (cost ?? 0.10))
        try JSONEncoder().encode(OpenUIJSON.object(budget)).write(to: evidence.appendingPathComponent("acceptance.json"), options: .atomic)
        XCTAssertLessThanOrEqual(previous + (cost ?? 0.10), 5)
        let description = result.object["text"]?.text ?? "", costText = cost.map { String($0) } ?? "unreported"
        print("Native Interactions video understanding: \(description); cost USD \(costText)")
    }
    func testApprovedSingleImageAndFourSecondVideo() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MORROW_LIVE_MEDIA"] == "1", let path = env["MORROW_LIVE_MEDIA_EVIDENCE"], let key = env["LEARNINGS_API_KEY"], !key.isEmpty else { throw XCTSkip("Paid media acceptance requires explicit opt-in and private evidence directory") }
        let evidence = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let model = AppModel(root: evidence.appendingPathComponent("runtime"), notifications: LiveMediaNotifications()); model.settings.enabled = false
        let config = try GatewayMediaConfiguration.load()
        model.gatewayMediaClientOverride = GatewayMediaClient(configuration: config, apiKey: key)
        let session = "approved-media-2026-11-02", context = SDKChatContext(sessionID: session, instruction: "生成虚构验收素材", ui: nil, runID: nil, allowedIDs: [], agreement: nil)
        model.chatSessions = [ChatSession(id: session)]
        _ = try await model.store.saveSessionMetadata(model.chatSessions[0])
        context.workspaceLease = try await model.sessionWorkspaces.open(session)
        func tool(_ name: String, _ call: String, _ args: [String: OpenUIJSON]) async throws -> OpenUIJSON {
            try await model.performSDKTool(.object(["name": .string(name), "callId": .string(call), "args": .object(args)]), context: context)
        }
        let image = try await tool("generate_image", "approved-image-one", ["model": .string("gpt-image-2.5-flare"), "prompt": .string("A simple flat illustration of a blue ceramic teapot on a cream background, no words, no people."), "quality": .string("low"), "size": .string("1024x1024")])
        let imageCost = try XCTUnwrap(Double(image.object["costUSD"]?.text ?? ""), "Actual image cost is required before submitting video")
        XCTAssertGreaterThanOrEqual(imageCost, 0); guard imageCost + 0.60 <= 5 else { throw MailError.message("Acceptance budget exhausted; video was not submitted") }
        let imageFile = try XCTUnwrap(context.generatedMedia.first)
        let imageBytes = try await model.sessionWorkspaces.read(imageFile.path, lease: imageFile.lease)
        try imageBytes.write(to: evidence.appendingPathComponent("image." + (imageFile.mimeType == "image/jpeg" ? "jpg" : "png")), options: .atomic)
        try JSONEncoder().encode(image).write(to: evidence.appendingPathComponent("image-receipt.json"), options: .atomic)
        print("Approved image generated: \(imageBytes.count) bytes; gateway cost USD \(imageCost)")
        let video = try await tool("generate_video", "approved-video-one", ["model": .string("veo-3.1-fast-generate-preview"), "prompt": .string("A small blue wooden cube slowly rotating on a plain cream tabletop. Static camera, simple studio lighting, no people, no text."), "seconds": .number(4), "size": .string("1280x720")])
        try JSONEncoder().encode(video).write(to: evidence.appendingPathComponent("video-submission.json"), options: .atomic)
        let jobID = try XCTUnwrap(video.object["jobID"]?.text)
        print("Approved single 4-second video submitted; polling existing job only")
        var complete: OpenUIJSON?
        for index in 0..<90 {
            let status = try await tool("check_media_job", "approved-video-poll-\(index)", ["jobID": .string(jobID)])
            try JSONEncoder().encode(status).write(to: evidence.appendingPathComponent("video-status.json"), options: .atomic)
            if status.object["path"] != nil { complete = status; break }
            let state = status.object["status"]?.text ?? "unknown"
            if state == "failed" { throw MailError.message("Approved video failed; no resubmission") }
            print("Approved video status: \(state)")
            try await Task.sleep(for: .seconds(10))
        }
        _ = try XCTUnwrap(complete, "Existing video job did not complete within 15 minutes")
        let file = try XCTUnwrap(context.generatedMedia.first { $0.mimeType == "video/mp4" })
        let bytes = try await model.sessionWorkspaces.read(file.path, lease: file.lease)
        try bytes.write(to: evidence.appendingPathComponent("video.mp4"), options: .atomic)
        let videoCost = max(Double(video.object["costUSD"]?.text ?? "") ?? 0.60, 0.60)
        let receipt: OpenUIJSON = .object(["imageGatewayCostUSD": .number(imageCost), "videoSubmissionCostUSD": video.object["costUSD"] ?? .null, "videoRateEstimateUSD": .number(0.60), "totalUSD": .number(imageCost + videoCost), "capUSD": .number(5), "videoSeconds": .number(4), "videoBytes": .number(Double(bytes.count))])
        try JSONEncoder().encode(receipt).write(to: evidence.appendingPathComponent("acceptance.json"), options: .atomic)
        XCTAssertLessThanOrEqual(imageCost + videoCost, 5)
        print("Approved video completed: \(bytes.count) bytes; total USD \(imageCost + videoCost) (video uses submission cost or published rate estimate)")
    }
}
@MainActor private final class LiveMediaNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
