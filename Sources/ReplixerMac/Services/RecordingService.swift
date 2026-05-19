import AVFoundation
import ScreenCaptureKit
import CoreMedia

// Records both microphone and VoIP-app audio, mixes them into a single M4A file.
//
// Strategy:
//   - AVAudioEngine captures microphone → temp PCM file
//   - SCStream sample buffers (from AudioTapService) → temp PCM file
//   - After call ends: mix both PCM files via AVMutableComposition → export M4A
@MainActor
final class RecordingService: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var currentSession: CallSession?

    var onRecordingFinished: ((URL, CallSession, Double) -> Void)?

    private var engine = AVAudioEngine()
    private var mixerNode = AVAudioMixerNode()
    private var micFile: AVAudioFile?
    private var micTempURL: URL?

    private var appAudioWriter: AVAssetWriter?
    private var appAudioInput: AVAssetWriterInput?
    private var appTempURL: URL?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Start / Stop

    func startRecording(session: CallSession) throws {
        guard !isRecording else { return }
        currentSession = session
        isRecording = true

        let timestamp = DateFormatter.fileTimestamp.string(from: session.startedAt)
        let base = settings.recordingsDirectory
            .appendingPathComponent("\(session.appName)_\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        micTempURL = base.appendingPathComponent("mic.caf")
        appTempURL = base.appendingPathComponent("app.caf")

        try startMicEngine()
        try startAppWriter()
    }

    func stopRecording() async throws -> URL? {
        guard isRecording, let session = currentSession else { return nil }
        isRecording = false
        currentSession = nil

        stopMicEngine()
        await stopAppWriter()

        return try await mixAndExport(session: session)
    }

    // MARK: - Mic recording (AVAudioEngine)

    private func startMicEngine() throws {
        engine = AVAudioEngine()
        engine.attach(mixerNode)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let recordFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

        engine.connect(inputNode, to: mixerNode, format: inputFormat)

        guard let url = micTempURL else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        micFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        mixerNode.installTap(onBus: 0, bufferSize: 4096, format: recordFormat) { [weak self] buffer, _ in
            guard let self, let file = self.micFile else { return }
            try? file.write(from: buffer)
        }

        try engine.start()
    }

    private func stopMicEngine() {
        mixerNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
    }

    // MARK: - App audio recording (CMSampleBuffer from SCStream)

    private func startAppWriter() throws {
        guard let url = appTempURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        appAudioWriter = writer
        appAudioInput = input
    }

    // Called from AudioTapService via AppViewModel for each SCStream audio buffer
    nonisolated func appendAppBuffer(_ sampleBuffer: CMSampleBuffer) {
        Task { @MainActor in
            guard self.isRecording,
                  let input = self.appAudioInput,
                  input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    private func stopAppWriter() async {
        guard let writer = appAudioWriter, let input = appAudioInput else { return }
        input.markAsFinished()
        await writer.finishWriting()
        appAudioWriter = nil
        appAudioInput = nil
    }

    // MARK: - Mix + Export

    private func mixAndExport(session: CallSession) async throws -> URL? {
        let composition = AVMutableComposition()
        var duration = CMTime.zero

        // Add mic track
        if let micURL = micTempURL, FileManager.default.fileExists(atPath: micURL.path) {
            let micAsset = AVURLAsset(url: micURL)
            let micDuration = try await micAsset.load(.duration)
            if let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: micDuration), of: micTrack, at: .zero)
                if micDuration > duration { duration = micDuration }
            }
        }

        // Add app audio track
        if let appURL = appTempURL, FileManager.default.fileExists(atPath: appURL.path) {
            let appAsset = AVURLAsset(url: appURL)
            let appDuration = try await appAsset.load(.duration)
            if let appTrack = try await appAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: appDuration), of: appTrack, at: .zero)
                if appDuration > duration { duration = appDuration }
            }
        }

        let durationSecs = CMTimeGetSeconds(duration)
        guard durationSecs > 0.5 else { return nil } // discard noise / accidental short recordings

        // Build output file name
        let timestamp = DateFormatter.fileTimestamp.string(from: session.startedAt)
        let outputURL = settings.recordingsDirectory
            .appendingPathComponent("\(session.appName)_\(settings.managerName)_\(timestamp).m4a")

        // Export as M4A / AAC
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.exporterUnavailable
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        await exporter.export()

        if let error = exporter.error { throw error }
        guard exporter.status == .completed else { throw RecordingError.exportFailed }

        // Clean up temp files
        [micTempURL, appTempURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
        if let parent = micTempURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: parent)
        }

        onRecordingFinished?(outputURL, session, durationSecs)
        return outputURL
    }

    enum RecordingError: Error {
        case exporterUnavailable
        case exportFailed
    }
}

// MARK: - Helpers
private extension DateFormatter {
    static let fileTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
