import ScreenCaptureKit
import CoreMedia
import AVFoundation
import Combine

// MARK: - Monitored app descriptor
struct MonitoredApp {
    let bundleID: String
    let displayName: String
}

// MARK: - AudioTapService
// Uses ScreenCaptureKit to tap per-app audio without needing UI Automation.
// Detects call start/end based on sustained audio level above a configurable threshold.
@MainActor
final class AudioTapService: NSObject, ObservableObject {

    // Events consumed by AppViewModel
    var onCallStarted: ((CallSession) -> Void)?
    var onCallEnded:   ((CallSession) -> Void)?

    // Expose sample buffers to RecordingService for mixing
    var onAppAudioBuffer: ((CMSampleBuffer, String) -> Void)?

    @Published private(set) var isMonitoring = false
    @Published private(set) var activeCallSessions: [String: CallSession] = [:]

    private var activeTaps:  [String: SCStream] = [:]   // bundleID → stream
    private var levelState:  [String: LevelState] = [:] // bundleID → detector state
    private var pollTask:    Task<Void, Never>?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        await refreshTaps()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshTaps()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
        for stream in activeTaps.values {
            Task { try? await stream.stopCapture() }
        }
        activeTaps.removeAll()
        levelState.removeAll()
    }

    // MARK: - Tap management

    private func refreshTaps() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return }

        let runningBundleIDs = Set(
            content.applications
                .map(\.bundleIdentifier)
                .filter { settings.monitoredBundleIDs.contains($0) }
        )

        // Start new taps
        for bundleID in runningBundleIDs where activeTaps[bundleID] == nil {
            if let stream = await buildStream(bundleID: bundleID, content: content) {
                do {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .utility))
                    try await stream.startCapture()
                    activeTaps[bundleID] = stream
                    levelState[bundleID] = LevelState()
                } catch {
                    print("[AudioTap] startCapture failed for \(bundleID): \(error)")
                }
            }
        }

        // Remove stale taps
        for bundleID in activeTaps.keys where !runningBundleIDs.contains(bundleID) {
            if let stream = activeTaps.removeValue(forKey: bundleID) {
                Task { try? await stream.stopCapture() }
            }
            levelState.removeValue(forKey: bundleID)
            await handleCallEnded(bundleID: bundleID)
        }
    }

    private func buildStream(bundleID: String, content: SCShareableContent) async -> SCStream? {
        guard let display = content.displays.first else { return nil }

        let filter: SCContentFilter

        if #available(macOS 14.2, *) {
            // Clean include-only filter
            if let scApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
            } else {
                return nil
            }
        } else {
            // macOS 13: exclude everything except the target app
            let appsToExclude = content.applications.filter { $0.bundleIdentifier != bundleID }
            filter = SCContentFilter(display: display, excludingApplications: appsToExclude, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 44_100
        config.channelCount = 2
        // Minimise video overhead — audio-only detection
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2
        config.pixelFormat = kCVPixelFormatType_32BGRA

        return SCStream(filter: filter, configuration: config, delegate: self)
    }

    // MARK: - Level state machine

    private struct LevelState {
        var aboveThresholdStart: Date?   // when sustained loud audio began
        var belowThresholdStart: Date?   // when sustained silence began
        var isCallActive = false
    }

    private func processLevel(_ db: Float, bundleID: String) {
        guard var state = levelState[bundleID] else { return }
        let threshold = settings.callStartThresholdDB
        let confirmSec = settings.callStartConfirmSeconds
        let silenceSec = settings.callEndSilenceSeconds
        let now = Date()

        if db > threshold {
            state.belowThresholdStart = nil
            if !state.isCallActive {
                if let start = state.aboveThresholdStart {
                    if now.timeIntervalSince(start) >= confirmSec {
                        state.isCallActive = true
                        Task { @MainActor in await self.handleCallStarted(bundleID: bundleID) }
                    }
                } else {
                    state.aboveThresholdStart = now
                }
            }
        } else {
            state.aboveThresholdStart = nil
            if state.isCallActive {
                if let start = state.belowThresholdStart {
                    if now.timeIntervalSince(start) >= silenceSec {
                        state.isCallActive = false
                        Task { @MainActor in await self.handleCallEnded(bundleID: bundleID) }
                    }
                } else {
                    state.belowThresholdStart = now
                }
            }
        }

        levelState[bundleID] = state
    }

    // MARK: - Call event handlers (main actor)

    private func handleCallStarted(bundleID: String) async {
        guard activeCallSessions[bundleID] == nil else { return }
        let appName = displayName(for: bundleID)
        let session = CallSession(bundleID: bundleID, appName: appName)
        activeCallSessions[bundleID] = session
        onCallStarted?(session)
    }

    private func handleCallEnded(bundleID: String) async {
        guard var session = activeCallSessions.removeValue(forKey: bundleID) else { return }
        session.end()
        onCallEnded?(session)
    }

    private func displayName(for bundleID: String) -> String {
        let map: [String: String] = [
            "ru.keepcoder.Telegram": "Telegram",
            "org.telegram.desktop": "Telegram",
            "com.viber": "Viber",
            "net.whatsapp.WhatsApp": "WhatsApp",
        ]
        return map[bundleID] ?? bundleID
    }
}

// MARK: - SCStreamOutput
extension AudioTapService: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }

        // Identify which app this stream belongs to
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let bundleID = self.activeTaps.first(where: { $0.value === stream })?.key else { return }
            let db = Self.rmsDBFS(sampleBuffer)
            self.processLevel(db, bundleID: bundleID)
            self.onAppAudioBuffer?(sampleBuffer, bundleID)
        }
    }

    // Compute RMS loudness in dBFS from a PCM CMSampleBuffer
    private static func rmsDBFS(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard
            let block = sampleBuffer.dataBuffer,
            case let length = block.dataLength, length > 0,
            let rawBytes = try? block.dataBytes()
        else { return -100 }

        let sampleCount = length / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return -100 }

        return rawBytes.withUnsafeBytes { ptr -> Float in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float32.self) else { return -100 }
            var sumSquares: Float = 0
            for i in 0 ..< sampleCount {
                let s = base[i]
                sumSquares += s * s
            }
            let rms = sqrt(sumSquares / Float(sampleCount))
            guard rms > 0 else { return -100 }
            return 20 * log10(rms)
        }
    }
}

// MARK: - SCStreamDelegate
extension AudioTapService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioTap] Stream stopped with error: \(error)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let bundleID = self.activeTaps.first(where: { $0.value === stream })?.key {
                self.activeTaps.removeValue(forKey: bundleID)
            }
        }
    }
}

// MARK: - CMBlockBuffer helper
private extension CMBlockBuffer {
    func dataBytes() throws -> Data {
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(self, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else {
            throw NSError(domain: "CMBlockBuffer", code: Int(status))
        }
        return Data(bytes: ptr, count: length)
    }
}
