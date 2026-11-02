import SwiftUI
import AVKit
import MorrowCore

private actor AgentMediaPreviewLoader {
    static let shared = AgentMediaPreviewLoader()
    func thumbnail(_ data: Data) -> MaterialThumbnail? { MaterialThumbnailCache.decode(data, maximumPixels: 640) }
}
private struct WorkspaceMediaSaveRecord: Codable { let materialID: String }

struct AgentMediaPreview: View {
    let file: AgentWorkspaceMedia
    @EnvironmentObject private var model: AppModel
    @State private var thumbnail: MaterialThumbnail?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var available = false
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    private var archived: Bool { model.chatSessions.first { $0.id == file.lease.sessionID }?.archived == true }
    private var title: String { WorkspaceMediaPresentation.title(file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(title, systemImage: file.mimeType.hasPrefix("video/") ? "film" : "photo").font(Theme.body.weight(.medium)).lineLimit(1); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).font(Theme.small).foregroundStyle(Theme.secondary) }
            if available {
                if let thumbnail { Image(decorative: thumbnail.image, scale: 2).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius)).accessibilityLabel(title) }
                else if let player { AgentVideoPlayer(player: player).frame(maxWidth: .infinity).frame(height: 180) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { playback; retain; export }
                    VStack(alignment: .leading, spacing: 8) { playback; HStack(spacing: 8) { retain; export } }
                }.buttonStyle(CompactButtonStyle())
                Text(L10n.t(saved ? "已保留为聊天资料" : "临时文件，归档后清理")).font(Theme.small).foregroundStyle(Theme.muted)
            } else if loading { ProgressView(L10n.t("正在准备预览…")).font(Theme.label) }
            else { Text(L10n.t(archived ? "临时工作区已清理" : "临时文件不可用")).font(Theme.label).foregroundStyle(Theme.secondary) }
        }.padding(.vertical, 8)
            .task(id: file.id + String(archived)) {
                loading = true; available = false; player?.pause(); player = nil; thumbnail = nil; playing = false
                defer { loading = false }
                do {
                    let material = try await model.savedWorkspaceMedia(file); saved = material != nil
                    let url: URL
                    if let material { url = try model.workspaceMaterialURL(material) }
                    else { url = try await model.sessionWorkspaces.file(file.path, lease: file.lease) }
                    if file.mimeType.hasPrefix("image/") { let bytes = try await model.workspaceMediaData(file, maximumBytes: 64 * 1024 * 1024); thumbnail = await AgentMediaPreviewLoader.shared.thumbnail(bytes) }
                    else if file.mimeType.hasPrefix("video/") { player = AVPlayer(url: url) }
                    try Task.checkCancellation(); available = true
                } catch { available = false }
            }.onDisappear { player?.pause(); player = nil; thumbnail = nil; playing = false }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in if let item = notification.object as? AVPlayerItem, item === player?.currentItem { playing = false } }
            .accessibilityIdentifier("chat.media.preview")
    }
    @ViewBuilder private var playback: some View {
        if let player { Button(L10n.t(playing ? "暂停" : "播放")) {
            if playing { player.pause() }
            else { let duration = player.currentItem?.duration.seconds ?? .nan; if duration.isFinite && player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }; player.play() }
            playing.toggle()
        }.accessibilityIdentifier("chat.media.play") }
    }
    private var retain: some View { Button(L10n.t(saved ? "已保留" : "保留文件")) { saving = true; Task { defer { saving = false }; do { try await model.saveWorkspaceMedia(file); saved = true } catch { model.error = error.localizedDescription } } }.disabled(saving || saved).accessibilityIdentifier("chat.media.save") }
    private var export: some View { Button(L10n.t("导出")) { model.exportWorkspaceMedia(file) }.accessibilityIdentifier("chat.media.export") }
}

enum WorkspaceMediaPresentation {
    static func title(_ file: AgentWorkspaceMedia) -> String {
        let stem = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
        if stem.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil { return L10n.t(file.mimeType.hasPrefix("video/") ? "生成视频" : "生成图片") }
        return file.name
    }
    static func filename(_ file: AgentWorkspaceMedia) -> String { title(file) == file.name ? file.name : (file.mimeType.hasPrefix("video/") ? "Morrow-video" : "Morrow-image") + "." + URL(fileURLWithPath: file.name).pathExtension }
}

struct AgentVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .inline; view.videoGravity = .resizeAspect; view.player = player; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

extension AppModel {
    private func workspaceMediaSaveID(_ file: AgentWorkspaceMedia) -> String { MailStore.hash(file.lease.sessionID + ":" + file.lease.generation + ":" + file.id) }
    func workspaceMaterialURL(_ material: ChatMaterial) throws -> URL {
        let root = store.root.standardizedFileURL.resolvingSymlinksInPath(), url = root.appendingPathComponent(material.path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.appendingPathComponent("chat-assets").path + "/") else { throw MailError.message("资料路径无效。") }
        return url
    }
    func savedWorkspaceMedia(_ file: AgentWorkspaceMedia) async throws -> ChatMaterial? {
        guard let record = try await store.object(WorkspaceMediaSaveRecord.self, kind: "workspace-media-save", id: workspaceMediaSaveID(file)),
              let material = try await store.object(ChatMaterial.self, kind: "chat-material", id: record.materialID),
              let values = try? workspaceMaterialURL(material).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, values.fileSize == material.byteCount else { return nil }
        return material
    }
    func workspaceMediaData(_ file: AgentWorkspaceMedia, maximumBytes: Int) async throws -> Data {
        if let material = try await savedWorkspaceMedia(file) { let url = try workspaceMaterialURL(material); return try await Task.detached(priority: .utility) { try BoundedFileReader.read(url, maximumBytes: maximumBytes) }.value }
        return try await sessionWorkspaces.read(file.path, lease: file.lease, maximumBytes: maximumBytes)
    }
    func refreshWorkspaceVideoJob(_ job: AgentWorkspaceVideoJob, chatID: String) async throws -> String {
        guard !isQualityPreview, chatSessions.contains(where: { $0.id == job.lease.sessionID && !$0.archived }) else { throw CancellationError() }
        let context = SDKChatContext(sessionID: job.lease.sessionID, instruction: "只读查询视频生成进度", ui: nil, runID: nil, allowedIDs: [], agreement: nil); context.workspaceLease = job.lease
        let reply = try await performSDKMediaTool("check_media_job", args: ["jobID": .string(job.id)], context: context, callID: "preview-" + job.id)
        if !context.generatedMedia.isEmpty, var message = chat.first(where: { $0.id == chatID }) {
            var files = message.workspaceMedia ?? []; for file in context.generatedMedia where !files.contains(where: { $0.id == file.id }) { files.append(file) }
            message.workspaceMedia = files; message.workspaceVideoJobs?.removeAll { $0.id == job.id }; try await recordChat(message); return "completed"
        }
        return reply.object["status"]?.text ?? "unknown"
    }
    func saveWorkspaceMedia(_ file: AgentWorkspaceMedia) async throws {
        if try await savedWorkspaceMedia(file) != nil { return }
        let data = try await sessionWorkspaces.read(file.path, lease: file.lease, maximumBytes: 32 * 1024 * 1024)
        let material = try await addChatData(data, name: WorkspaceMediaPresentation.filename(file), mime: file.mimeType, sessionID: file.lease.sessionID)
        try await store.save(WorkspaceMediaSaveRecord(materialID: material.id), kind: "workspace-media-save", id: workspaceMediaSaveID(file))
    }
    func exportWorkspaceMedia(_ file: AgentWorkspaceMedia) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = WorkspaceMediaPresentation.filename(file)
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            Task { do { let data = try await self.workspaceMediaData(file, maximumBytes: 128 * 1024 * 1024); try data.write(to: target, options: .atomic) } catch { self.error = error.localizedDescription } }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completed) } else { panel.begin(completionHandler: completed) }
    }
}

struct AgentVideoJobPreview: View {
    let job: AgentWorkspaceVideoJob
    let chatID: String
    @EnvironmentObject private var model: AppModel
    @State private var status = "视频正在生成…"
    @State private var retry = 0
    private var archived: Bool { model.chatSessions.first { $0.id == job.lease.sessionID }?.archived == true }
    var body: some View {
        HStack(spacing: 8) {
            Label(L10n.t(archived ? "临时工作区已清理" : status), systemImage: "film").lineLimit(2)
            if !archived { Spacer(minLength: 4); Button(L10n.t("检查进度")) { retry += 1 }.buttonStyle(.plain).disabled(model.isQualityPreview) }
        }.font(Theme.label).foregroundStyle(Theme.secondary).padding(.vertical, 8)
            .task(id: job.id + String(archived) + String(retry)) {
                guard !archived, !model.isQualityPreview else { return }
                do {
                    for _ in 0..<90 { let value = try await model.refreshWorkspaceVideoJob(job, chatID: chatID); if value == "completed" { return }; if value == "failed" { status = "视频未生成，请查看任务详情"; return }; try await Task.sleep(for: .seconds(10)) }
                    status = "视频仍在处理，可继续检查进度"
                } catch { if !Task.isCancelled { status = "暂时无法获取视频进度" } }
            }.accessibilityIdentifier("chat.media.video-job")
    }
}
