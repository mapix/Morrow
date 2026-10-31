import Foundation
import Speech
import AVFoundation
import AudioToolbox
import Combine

/// SpeechAnalyzer runs on device. Assets come from Apple's system inventory.
enum LocalSpeech {
    static func module() async throws -> SpeechTranscriber {
        let language = L10n.languageCode
        let requested = language == "zh-Hans" ? "zh-CN" : language == "ja" ? "ja-JP" : "en-US"
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: requested)) else { throw NSError(domain: "MorrowSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.t("本机暂不支持所选语言的语音识别。")] ) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        return transcriber
    }
    static func transcribeFile(_ url: URL) async throws -> String {
        let transcriber = try await module(), analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { var text = ""; for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }; return text }
        do { try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true); return try await resultTask.value }
        catch { resultTask.cancel(); await analyzer.cancelAndFinishNow(); throw error }
    }
}
@MainActor final class NativeVoiceInput: ObservableObject {
    @Published var recording = false
    @Published var preparing = false
    @Published var finalizing = false
    private var generation = UUID()
    private var tapInstalled = false
    @Published var transcript = ""
    @Published var error: String?
    @Published var level: Float = 0
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    func start() async {
        guard !recording, !preparing, !finalizing else { return }; error = nil; transcript = ""; preparing = true; let token = generation; defer { preparing = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "需要麦克风权限才能录音。可以在系统设置中允许Morrow访问麦克风。"; return }
        do {
            let transcriber = try await LocalSpeech.module()
            guard generation == token else { return }
            let input = engine.inputNode, natural = input.outputFormat(forBus: 0)
            guard natural.sampleRate > 0, let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural), let converter = AVAudioConverter(from: natural, to: format) else { throw NSError(domain: "MorrowSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "麦克风音频格式不可用。"] ) }
            let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(); self.continuation = continuation
            resultsTask = Task { [weak self] in
                var finalized = ""
                do { for try await result in transcriber.results { guard let self else { return }; let text = String(result.text.characters); if result.isFinal { finalized += text; self.transcript = finalized } else { self.transcript = finalized + text } } }
                catch { self?.error = error.localizedDescription; self?.stop() }
            }
            try await analyzer.start(inputSequence: stream)
            guard generation == token else { await analyzer.cancelAndFinishNow(); return }
            input.installTap(onBus: 0, bufferSize: 2048, format: natural) { [weak self] buffer, _ in
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate) + 256) else { return }
                var supplied = false; var failure: NSError?
                let status = converter.convert(to: output, error: &failure) { _, state in if supplied { state.pointee = .noDataNow; return nil }; supplied = true; state.pointee = .haveData; return buffer }
                if status != .error, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
                if let channel = buffer.floatChannelData?[0] { let values = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)); let amplitude = values.reduce(Float(0)) { $0 + abs($1) } / Float(max(1, buffer.frameLength)); Task { @MainActor in self?.level = min(1, amplitude * 8) } }
            }
            tapInstalled = true; engine.prepare(); try engine.start(); recording = true
            timeout = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { stop() } }
        } catch { self.error = error.localizedDescription; if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }; await analyzer?.cancelAndFinishNow(); analyzer = nil; resultsTask?.cancel(); continuation?.finish(); continuation = nil }
    }
    func stop() {
        guard recording else { return }; recording = false; engine.stop(); engine.inputNode.removeTap(onBus: 0); tapInstalled = false; continuation?.finish(); continuation = nil; timeout?.cancel(); timeout = nil; level = 0
        let current = analyzer; finalizing = true
        Task { do { try await current?.finalizeAndFinishThroughEndOfInput(); await resultsTask?.value } catch { self.error = error.localizedDescription }; finalizing = false }
    }
    func cancel() { generation = UUID(); stop(); resultsTask?.cancel(); resultsTask = nil; let current = analyzer; analyzer = nil; Task { await current?.cancelAndFinishNow() } }
}
