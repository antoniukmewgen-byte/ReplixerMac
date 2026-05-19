import Foundation

struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let filePath: String
    let appName: String
    let managerName: String
    let createdAt: Date
    let durationSeconds: Double
    var uploadState: UploadState

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var fileSizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
    }

    enum UploadState: String, Codable {
        case pending
        case uploadingDrive
        case uploadingTelegram
        case done
        case failed
    }
}

extension Recording {
    static func make(session: CallSession, fileURL: URL, duration: Double, managerName: String) -> Recording {
        Recording(
            id: UUID(),
            fileName: fileURL.lastPathComponent,
            filePath: fileURL.path,
            appName: session.appName,
            managerName: managerName,
            createdAt: session.startedAt,
            durationSeconds: duration,
            uploadState: .pending
        )
    }
}
