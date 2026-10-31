import SwiftUI
import MorrowCore
import PhotosUI
import UniformTypeIdentifiers
import Speech
import AVFoundation
import CoreTransferable
import ImageIO

struct MobileChat: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) var dismiss
    @State var sessionList = false
    @State var importFile = false
    @State var photo: PhotosPickerItem?
    @State private var photoNotice: String?
    @StateObject var voice = MobileVoice()
    @AppStorage("SmailMobileTheme") var theme = "coral"
    var input: Binding<String> { let origin = model.currentSessionID; return Binding(get: { model.sessions.first(where: { $0.id == origin })?.input ?? "" }, set: { text in guard var session = model.sessions.first(where: { $0.id == origin }) else { return }; session.input = text; session.draftRevision += 1; model.sessions = model.sessions.map { $0.id == origin ? session : $0 }; Task { await model.updateSession(session) } }) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let scope = model.currentSession?.pinnedContext ?? model.context { HStack { Image(systemName: "link"); Text(scope.label).lineLimit(1).accessibilityIdentifier("chat.scope"); Spacer(); Button { guard var session = model.currentSession else { return }; session.pinnedContext = session.pinnedContext == nil ? model.context : nil; session.draftRevision += 1; Task { await model.updateSession(session) } } label: { Image(systemName: model.currentSession?.pinnedContext == nil ? "pin" : "pin.fill") }.accessibilityLabel(MobileL10n.text("固定当前上下文")) }.font(.caption).padding(.horizontal, 18).padding(.vertical, 10).background(MobilePalette.value(theme).paper) }
                ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 20) {
                    if model.currentChats.isEmpty { Text(MobileL10n.text("给伙伴的委托")).font(.title2).fontWeight(.semibold).padding(.top, 22); Text(MobileL10n.text("查找相关往来，拟定回复，整理附件，记住你的偏好。")).foregroundStyle(.secondary).padding(.bottom, 20) }
                    ForEach(model.currentChats) { chat in VStack(alignment: .leading, spacing: 10) { Text(chat.role == "user" ? "You" : "Morrow").font(.caption).fontWeight(.semibold).foregroundStyle(MobilePalette.value(theme).accent); Text(chat.text).textSelection(.enabled).font(.body).lineSpacing(4); if let materials = chat.materials { ForEach(materials) { item in Label(item.name, systemImage: "paperclip").font(.caption) } }; ForEach(chat.messageIDs, id: \.self) { id in if let mail = model.mails.first(where: { $0.id == id }) { NavigationLink(mail.subject) { MobileReader(mailID: id) }.font(.caption) } } }.id(chat.id) }
                    ForEach(model.interactions.filter { $0.sessionID == model.currentSessionID }) { page in MobileOpenUI(interaction: page).environmentObject(model) }
                    if model.busy { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(20) }.onChange(of: model.currentChats.count) { _, _ in if let last = model.currentChats.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } } } }
                VStack(spacing: 10) {
                    if let items = model.currentSession?.materials, !items.isEmpty { ScrollView(.horizontal) { HStack { ForEach(items) { item in HStack { Text(item.name).font(.caption).lineLimit(1); Button { guard var session = model.currentSession else { return }; session.materials.removeAll { $0.id == item.id }; session.draftRevision += 1; Task { await model.updateSession(session) } } label: { Image(systemName: "xmark.circle.fill") } }.padding(8).background(.quaternary, in: Capsule()) } } } }
                    if let photoNotice { Text(photoNotice).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("photo.import.status") }
                    if voice.recording { HStack { Image(systemName: "waveform"); Text(voice.transcript.isEmpty ? MobileL10n.text("语音输入") : voice.transcript).lineLimit(2) }.font(.caption).foregroundStyle(MobilePalette.value(theme).accent) }
                    TextField(MobileL10n.text("给伙伴的委托"), text: input, axis: .vertical).lineLimit(2...6).padding(12).background(MobilePalette.value(theme).paper, in: RoundedRectangle(cornerRadius: 12)).autocorrectionDisabled(true).id(model.currentSessionID).accessibilityIdentifier("chat.input")
                    HStack(spacing: 20) { Button { importFile = true } label: { Image(systemName: "paperclip") }.accessibilityLabel(MobileL10n.text("添加文件")); PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }.accessibilityLabel(MobileL10n.text("选择截图或图片")); Button { if voice.recording { voice.stop() } else { let target = model; let origin = model.currentSessionID; voice.onCommit = { text in Task { await target.appendVoice(text, sessionID: origin) } }; Task { do { try await voice.start() } catch { model.error = error.localizedDescription } } } } label: { Image(systemName: voice.recording ? "stop.circle.fill" : "mic") }.accessibilityLabel(MobileL10n.text(voice.recording ? "结束语音" : "语音输入")); Spacer(); Button { Task { await model.submit() } } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 40, height: 40) }.buttonStyle(.borderedProminent).disabled(model.busy || (input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.currentSession?.materials.isEmpty ?? true))).accessibilityLabel(MobileL10n.text("发送")).accessibilityIdentifier("chat.submit") }
                }.padding(16).background(MobilePalette.value(theme).sheet)
            }.navigationTitle(model.displaySessionTitle(model.currentSession)).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarLeading) { Button { sessionList = true } label: { Image(systemName: "sidebar.left") }.accessibilityLabel(MobileL10n.text("对话")) }; ToolbarItem(placement: .topBarTrailing) { Button(MobileL10n.text("完成")) { voice.stop(); dismiss() } } }
        }.sheet(isPresented: $sessionList) { MobileSessions().environmentObject(model) }.fileImporter(isPresented: $importFile, allowedContentTypes: [.item]) { result in if case .success(let url) = result { Task { await model.importMaterial(url) } } }.onChange(of: photo) { _, item in
            let origin = model.currentSessionID
            photoNotice = nil
            Task {
                do {
                    guard let imported = try await item?.loadTransferable(type: MobileImportedPhoto.self) else { return }
                    defer { try? FileManager.default.removeItem(at: imported.url) }
                    await model.importMaterial(imported.url, sessionID: origin)
                    if imported.compressed { photoNotice = MobileImportedPhoto.compressionNotice }
                } catch { model.error = error.localizedDescription }
            }
        }.onChange(of: model.navigationRevision) { _, _ in voice.stop(); dismiss() }.onDisappear { voice.stop() }
    }
}

struct MobileSessions: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) var dismiss
    @State var search = ""
    @State var archived = false
    var visible: [ChatSession] {
        model.orderedSessions.filter { $0.archived == archived && (search.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Toggle(MobileL10n.text("归档"), isOn: $archived)
                ForEach(visible) { session in
                    Button { model.selectSession(session.id); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.displaySessionTitle(session)).fontWeight(.medium)
                                Text(session.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.currentSessionID == session.id { Image(systemName: "checkmark") }
                        }
                    }.swipeActions {
                        Button(MobileL10n.text(session.archived ? "恢复" : "归档")) { Task { await model.archiveSession(session.id) } }
                    }
                }
            }
            .navigationTitle(MobileL10n.text("对话"))
            .searchable(text: $search, prompt: MobileL10n.text("搜索对话"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(MobileL10n.text("完成")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.newSession(); dismiss() } } label: { Image(systemName: "plus") }.accessibilityLabel(MobileL10n.text("创建对话"))
                }
            }
        }
    }
}

/// PhotosPicker supplies a file instead of eagerly materializing the original
/// image as Data/UIImage. Only an owned, bounded import file survives the callback.
private struct MobileImportedPhoto: Transferable, Sendable {
    let url: URL
    let compressed: Bool
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { photo in SentTransferredFile(photo.url) } importing: { received in
            try await Task.detached(priority: .utility) { try prepare(received.file) }.value
        }
    }
    @MainActor static var compressionNotice: String {
        if MobileL10n.language.hasPrefix("ja") { return "大きな画像を長辺2048px以下に縮小し、JPEGに圧縮しました。元画像は保存していません。" }
        if MobileL10n.language.hasPrefix("zh") { return "大图已缩小至最长边2048像素并压缩为JPEG，未保留原图副本。" }
        return "Large image resized to at most 2048 pixels and compressed as JPEG. The original was not retained."
    }
    private static func prepare(_ sourceURL: URL) throws -> MobileImportedPhoto {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw MailError.message("图片文件暂不可读取。") }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { throw MailError.message("图片格式无法读取。") }
        let compressed = max(width.intValue, height.intValue) > 2048 || size > 32 * 1024 * 1024
        let fileType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let suffix = compressed ? "jpg" : fileType?.preferredFilenameExtension ?? "image"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-photo-" + UUID().uuidString + "." + suffix)
        do {
            if compressed {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw MailError.message("图片无法缩小为JPEG。") }
                CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw MailError.message("图片压缩未完成。") }
            } else {
                try BoundedFileReader.read(sourceURL, maximumBytes: 32 * 1024 * 1024).write(to: output, options: .atomic)
            }
            return MobileImportedPhoto(url: output, compressed: compressed)
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}

@MainActor final class MobileVoice: NSObject, ObservableObject {
    @Published var recording = false
    @Published var transcript = ""
    var onCommit: ((String) -> Void)?
    private var committed = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    func start() async throws {
        let permission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard permission == .authorized else { throw MailError.message("请在系统设置中允许语音识别。") }
        guard await AVAudioApplication.requestRecordPermission() else { throw MailError.message("请在系统设置中允许麦克风。") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: MobileL10n.language)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw MailError.message("此设备尚未提供所选语言的本机语音识别。") }
        stop(commit: false); transcript = ""; committed = false
        let session = AVAudioSession.sharedInstance(); try session.setCategory(.record, mode: .measurement, options: .duckOthers); try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; self.request = request
        let node = engine.inputNode; node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in Task { @MainActor in if let result { self?.transcript = result.bestTranscription.formattedString }; if error != nil || result?.isFinal == true { self?.stop() } } }
        engine.prepare(); try engine.start(); recording = true
    }
    func stop(commit: Bool = true) { if commit && !committed && !transcript.isEmpty { committed = true; onCommit?(transcript) }; if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }; request?.endAudio(); task?.cancel(); request = nil; task = nil; recording = false; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
}
