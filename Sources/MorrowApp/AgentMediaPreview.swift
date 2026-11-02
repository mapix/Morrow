import SwiftUI
import AVKit
import MorrowCore

private actor AgentMediaPreviewLoader {
    static let shared = AgentMediaPreviewLoader()
    func thumbnail(_ file: AgentWorkspaceMedia, workspaces: AgentSessionWorkspaces) async throws -> MaterialThumbnail? {
        let data = try await workspaces.read(file.path, lease: file.lease, maximumBytes: 64 * 1024 * 1024)
        return MaterialThumbnailCache.decode(data, maximumPixels: 640)
    }
}

struct AgentMediaPreview: View {
    let file: AgentWorkspaceMedia
    @EnvironmentObject private var model: AppModel
    @State private var thumbnail: MaterialThumbnail?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var available = false
    @State private var saving = false
    @State private var saved = false
    private var archived: Bool { model.chatSessions.first { $0.id == file.lease.sessionID }?.archived == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(file.name, systemImage: file.mimeType.hasPrefix("video/") ? "film" : "photo").font(Theme.label).lineLimit(1)
            if available && !archived {
                if let thumbnail {
                    Image(decorative: thumbnail.image, scale: 2).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 240).accessibilityLabel(file.name)
                } else if let player {
                    AgentVideoPlayer(player: player).frame(maxWidth: 320).frame(height: 180)
                }
                HStack(spacing: 12) {
                    if let player {
                        Button(L10n.t(playing ? "暂停视频" : "播放视频")) {
                            if playing { player.pause() }
                            else {
                                let duration = player.currentItem?.duration.seconds ?? .nan
                                if duration.isFinite && player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
                                player.play()
                            }
                            playing.toggle()
                        }.accessibilityIdentifier("chat.media.play")
                    }
                    Button(L10n.t(saved ? "已保存到资料" : "保存到资料")) {
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await model.saveWorkspaceMedia(file); saved = true }
                            catch { model.error = error.localizedDescription }
                        }
                    }.disabled(saving || saved).accessibilityIdentifier("chat.media.save")
                    Button(L10n.t("导出文件")) { model.exportWorkspaceMedia(file) }.accessibilityIdentifier("chat.media.export")
                }.buttonStyle(CompactButtonStyle())
                Text(L10n.t("归档后清理临时文件")).font(Theme.label).foregroundStyle(Theme.muted)
            } else {
                Text(L10n.t(archived ? "会话已归档，临时文件已清理" : "临时文件不可用")).font(Theme.label).foregroundStyle(Theme.muted)
            }
        }.padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
            .task(id: file.id + String(archived)) {
                available = false; player?.pause(); player = nil; thumbnail = nil; playing = false
                guard !archived else { return }
                do {
                    let url = try await model.sessionWorkspaces.file(file.path, lease: file.lease)
                    if file.mimeType.hasPrefix("image/") { thumbnail = try await AgentMediaPreviewLoader.shared.thumbnail(file, workspaces: model.sessionWorkspaces) }
                    else if file.mimeType.hasPrefix("video/") { player = AVPlayer(url: url) }
                    try Task.checkCancellation(); available = true
                } catch { available = false }
            }.onDisappear { player?.pause(); player = nil; thumbnail = nil; playing = false }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                if let item = notification.object as? AVPlayerItem, item === player?.currentItem { playing = false }
            }
            .accessibilityIdentifier("chat.media.preview")
    }
}

struct AgentVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

extension AppModel {
    func refreshWorkspaceVideoJob(_ job: AgentWorkspaceVideoJob, chatID: String) async throws -> String {
        guard chatSessions.contains(where: { $0.id == job.lease.sessionID && !$0.archived }) else { throw CancellationError() }
        let context = SDKChatContext(sessionID: job.lease.sessionID, instruction: "只读查询视频生成进度", ui: nil, runID: nil, allowedIDs: [], agreement: nil)
        context.workspaceLease = job.lease
        let reply = try await performSDKMediaTool("check_media_job", args: ["jobID": .string(job.id)], context: context, callID: "preview-" + job.id)
        if !context.generatedMedia.isEmpty, var message = chat.first(where: { $0.id == chatID }) {
            var files = message.workspaceMedia ?? []
            for file in context.generatedMedia where !files.contains(where: { $0.id == file.id }) { files.append(file) }
            message.workspaceMedia = files; message.workspaceVideoJobs?.removeAll { $0.id == job.id }
            try await recordChat(message)
            return "completed"
        }
        return reply.object["status"]?.text ?? "unknown"
    }
    func saveWorkspaceMedia(_ file: AgentWorkspaceMedia) async throws {
        let data = try await sessionWorkspaces.read(file.path, lease: file.lease, maximumBytes: 32 * 1024 * 1024)
        try await addChatData(data, name: file.name, mime: file.mimeType, sessionID: file.lease.sessionID)
    }
    func exportWorkspaceMedia(_ file: AgentWorkspaceMedia) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            Task {
                do {
                    let data = try await self.sessionWorkspaces.read(file.path, lease: file.lease, maximumBytes: 128 * 1024 * 1024)
                    try data.write(to: target, options: .atomic)
                } catch { self.error = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completed) }
        else { panel.begin(completionHandler: completed) }
    }
}

struct AgentVideoJobPreview: View {
    let job: AgentWorkspaceVideoJob
    let chatID: String
    @EnvironmentObject private var model: AppModel
    @State private var status = "视频正在生成…"
    private var archived: Bool { model.chatSessions.first { $0.id == job.lease.sessionID }?.archived == true }
    var body: some View {
        Label(L10n.t(archived ? "会话已归档，视频工作区已清理" : status), systemImage: "film")
            .font(Theme.label).foregroundStyle(Theme.secondary).padding(12)
            .task(id: job.id + String(archived)) {
                guard !archived else { return }
                do {
                    for _ in 0..<90 {
                        let value = try await model.refreshWorkspaceVideoJob(job, chatID: chatID)
                        if value == "completed" { return }
                        if value == "failed" { status = "视频生成失败，可在对话中查看任务详情"; return }
                        try await Task.sleep(for: .seconds(10))
                    }
                    status = "视频仍在处理，可在对话中继续查询"
                } catch { if !Task.isCancelled { status = "视频进度暂不可用，可在对话中继续查询" } }
            }.accessibilityIdentifier("chat.media.video-job")
    }
}
