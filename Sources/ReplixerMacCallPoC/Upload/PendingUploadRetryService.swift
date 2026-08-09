import Foundation

/// Phase 6: background "catch up" for recordings where a Drive/Telegram
/// upload attempt failed (network hiccup, Telegram login not ready yet,
/// etc.) and never got fixed. The retry-once-after-a-short-delay logic
/// already inside `GoogleDriveUploadService`/`TelegramUploadService` only
/// covers a failure right at call-end time — if it still fails after that
/// single retry (e.g. no internet at all for a while), nothing would ever
/// try again without this. Windows parity source:
/// `PendingUploadRetryService.cs` (same 10s tick interval).
///
/// Deliberately just a ticker: the actual retry logic — including TDLib
/// client resolution/caching — lives in `CallRecordingCoordinator`, the
/// only actor that touches TDLib, via its `retryPendingUploads()` method.
/// Keeping that ownership in one place avoids a second place that could
/// race to create/login a second TDLib session.
///
/// Uses a plain `Task` loop instead of Windows' `System.Threading.Timer` +
/// `Interlocked`-guarded `_isTicking` flag — a `while` loop that `await`s
/// the previous tick's full completion before sleeping again can't overlap
/// itself, so no separate re-entrancy guard is needed here.
final class PendingUploadRetryService {
    private static let intervalNanoseconds: UInt64 = 10_000_000_000 // 10s, Windows-parity interval

    private let coordinator: CallRecordingCoordinator
    private var task: Task<Void, Never>?

    init(coordinator: CallRecordingCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard task == nil else { return } // already running
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: PendingUploadRetryService.intervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.coordinator.retryPendingUploads()
            }
        }
        print("[PendingUploadRetryService] 🔁 фоновий сервіс відновлення записів запущено (кожні 10с)")
    }

    /// Call before process exit — same "don't let a stray background task
    /// outlive shutdown" reasoning as `CallRecordingCoordinator.shutdown()`
    /// draining `pendingUploadTask`. Not awaited: cancellation just stops
    /// the *next* sleep/tick from starting, it doesn't need to interrupt an
    /// in-flight one (which is itself driven through the coordinator actor
    /// and will finish on its own).
    func stop() {
        task?.cancel()
        task = nil
    }
}
